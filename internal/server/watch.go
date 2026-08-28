package server

import (
	"net/http"
	"strconv"
	"sync"
	"time"
)

// 自动刷新的服务端一半。
//
// 浏览器用长轮询问"有变化了吗"：带上自己知道的版本号来，服务端要么立刻答（版本已经变了），
// 要么把这个请求挂住，等真有变化、或者等到超时才答。这样"改完到界面更新"的延迟只由服务端
// 的探测间隔决定，而不是由浏览器多久问一次决定；没变化的时候也几乎不产生流量。
//
// 探测循环**只在有人在等的时候才跑**：没人看着就自己停掉。twig 是常驻一整天的，
// 不能因为开着一个没人看的标签页就一直烧 CPU。
const (
	// watchPoll 是探测间隔。一次探测约等于一条 git status（colt 那种规模实测约 40ms），
	// 1.5 秒一次大概占单核百分之二三，人几乎感觉不到延迟。
	watchPoll = 1500 * time.Millisecond
	// watchTimeout 是一次长轮询最多挂多久。到点就答一个"没变化"，让浏览器立刻再问一次——
	// 中间隔着的任何一层（浏览器、代理）都可能对长连接有自己的空闲超时，主动短于它们更稳。
	watchTimeout = 25 * time.Second
	// watchIdle 是"多久没人来问就停掉探测"。浏览器标签页切到后台时就不再问了，
	// 于是这边也跟着停。
	watchIdle = 60 * time.Second
	// watchMaxLoad 是探测最多占多少 CPU。间隔按"上一次探测耗时的多少倍"往上抬，
	// 保证不管仓库多大，探测都只占一小片。
	//
	// 为什么需要：固定 1.5 秒间隔在中等仓库上没问题（实测 1120 个文件的仓库单次
	// 约 31ms，占 2%），但超大仓库的 git status 可能要半秒——那就成了三分之一个核，
	// 一台笔记本开着 twig 一天，风扇会转起来。
	watchMaxLoad = 10 // 间隔 >= 单次耗时 × 10，即最多占 1/10 个核
	// watchPollMax 是间隔上限：再大的仓库也不该等超过这个时间才发现变化。
	watchPollMax = 10 * time.Second
)

type watcher struct {
	s *Server

	mu      sync.Mutex
	version uint64
	key     string        // 仓库路径 + 指纹，两者任一变了都算变
	changed chan struct{} // 每次版本号变化就 close 掉、换一个新的（一对多广播）
	running bool
	lastAsk time.Time
}

func newWatcher(s *Server) *watcher {
	return &watcher{s: s, changed: make(chan struct{})}
}

// wait 是长轮询的核心：版本号跟调用方手上的不一样就立刻返回，一样就挂到有变化或超时。
func (w *watcher) wait(since uint64) uint64 {
	w.mu.Lock()
	w.lastAsk = time.Now()
	if !w.running {
		w.running = true
		go w.loop()
	}
	if w.version != since {
		v := w.version
		w.mu.Unlock()
		return v
	}
	ch := w.changed
	w.mu.Unlock()

	timer := time.NewTimer(watchTimeout)
	defer timer.Stop()
	select {
	case <-ch:
	case <-timer.C:
	}

	w.mu.Lock()
	defer w.mu.Unlock()
	return w.version
}

func (w *watcher) loop() {
	defer func() {
		w.mu.Lock()
		w.running = false
		w.mu.Unlock()
	}()

	wait := watchPoll
	for {
		time.Sleep(wait)

		w.mu.Lock()
		idle := time.Since(w.lastAsk) > watchIdle
		w.mu.Unlock()
		if idle {
			return
		}

		repo, err := w.s.currentRepo()
		if err != nil {
			continue
		}
		started := time.Now()
		fp, err := repo.Fingerprint()
		// 按这次实际花了多久，决定下一轮等多久：仓库越大等得越久，
		// 占用的 CPU 比例保持不变。小仓库照旧是 watchPoll。
		wait = time.Duration(time.Since(started)) * watchMaxLoad
		if wait < watchPoll {
			wait = watchPoll
		}
		if wait > watchPollMax {
			wait = watchPollMax
		}
		if err != nil {
			// 探测失败（仓库正被 git 改着、临时读不到）不该把版本号推走，
			// 否则界面会因为一次读失败白刷一遍。下一轮再说。
			continue
		}
		key := repo.Dir + "\x00" + fp

		w.mu.Lock()
		switch {
		case w.key == "":
			// 第一次只记下当前状态，不推版本号——浏览器刚刚才完整加载过一遍，
			// 这时候推一下等于让它无谓地再刷一次。
			w.key = key
		case key != w.key:
			w.key = key
			w.version++
			close(w.changed)
			w.changed = make(chan struct{})
		}
		w.mu.Unlock()
	}
}

// GET /api/watch?since=<版本号> —— 长轮询，仓库一变就返回新的版本号。
//
// 浏览器拿到的版本号跟自己带上来的不一样，就说明该重新拉数据了。
func (s *Server) handleWatch(w http.ResponseWriter, r *http.Request) {
	since, _ := strconv.ParseUint(r.URL.Query().Get("since"), 10, 64)
	v := s.watch.wait(since)
	writeJSON(w, map[string]any{"version": v})
}

// resync 把当前状态重新记成基线，但**不推版本号**。
//
// 用在 twig 自己做完写操作之后（提交、暂存、切分支……）。那些操作本来就会让界面
// 立刻刷新一次，指纹当然也跟着变了；不重记基线的话，探测循环下一轮会发现"变了"，
// 于是界面又白刷第二遍——大仓库上这一下很明显。
//
// 拿不到指纹就什么都不做：那样最多是多刷一次，而错误地清空基线会让下一轮
// 把"第一次"当成变化。
func (w *watcher) resync() {
	repo, err := w.s.currentRepo()
	if err != nil {
		return
	}
	fp, err := repo.Fingerprint()
	if err != nil {
		return
	}
	w.mu.Lock()
	w.key = repo.Dir + "\x00" + fp
	w.mu.Unlock()
}
