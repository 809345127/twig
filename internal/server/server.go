// Package server 提供 twig 的本地 HTTP 接口与静态页面。
package server

import (
	"crypto/rand"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"io/fs"
	"net"
	"net/http"
	"strings"
	"sync"

	"twig/internal/git"
)

// Server 是整个应用的运行时。
type Server struct {
	mu   sync.Mutex
	repo *git.Repo

	state *AppState
	// token 每次启动随机生成，接口调用必须带上，防止别的网页偷偷访问本机服务。
	token string
	web   fs.FS
}

// New 创建一个 Server。web 是内嵌的静态资源目录。
//
// token 传空则随机生成一个。传入已有令牌是为了让重启后的实例沿用同一个，
// 这样浏览器里存的书签不会因为重启而失效。
func New(web fs.FS, token string) *Server {
	if token == "" {
		buf := make([]byte, 16)
		_, _ = rand.Read(buf)
		token = hex.EncodeToString(buf)
	}
	return &Server{
		state: loadState(),
		token: token,
		web:   web,
	}
}

// Token 返回本次运行的接口令牌。
func (s *Server) Token() string { return s.token }

// Handler 组装路由。
func (s *Server) Handler() http.Handler {
	mux := http.NewServeMux()

	mux.HandleFunc("GET /api/ping", s.handlePing)
	mux.HandleFunc("GET /api/bootstrap", s.handleBootstrap)
	mux.HandleFunc("POST /api/open", s.handleOpen)
	mux.HandleFunc("POST /api/forget", s.handleForget)
	mux.HandleFunc("GET /api/browse", s.handleBrowse)
	mux.HandleFunc("GET /api/refs", s.handleRefs)
	mux.HandleFunc("GET /api/graph", s.handleGraph)
	mux.HandleFunc("GET /api/commit", s.handleCommit)
	mux.HandleFunc("GET /api/rangediff", s.handleRangeDiff)
	mux.HandleFunc("GET /api/patch", s.handlePatch)
	mux.HandleFunc("GET /api/status", s.handleStatus)
	mux.HandleFunc("GET /api/stashes", s.handleStashes)
	mux.HandleFunc("POST /api/op", s.handleOp)

	mux.Handle("/", http.FileServer(http.FS(s.web)))

	return s.guard(mux)
}

// guard 做两件事：拦掉不是发给本机的请求，以及校验接口令牌。
func (s *Server) guard(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		// 防 DNS rebinding：只接受指向本机的 Host。
		host := r.Host
		if h, _, err := net.SplitHostPort(host); err == nil {
			host = h
		}
		switch host {
		case "127.0.0.1", "localhost", "::1", "[::1]":
		default:
			http.Error(w, "local access only", http.StatusForbidden)
			return
		}

		if strings.HasPrefix(r.URL.Path, "/api/") {
			tok := r.Header.Get("X-Twig-Token")
			if tok == "" {
				tok = r.URL.Query().Get("token")
			}
			if tok != s.token {
				http.Error(w, "invalid token", http.StatusUnauthorized)
				return
			}
		}
		next.ServeHTTP(w, r)
	})
}

// —— 辅助 ——

func writeJSON(w http.ResponseWriter, v any) {
	w.Header().Set("Content-Type", "application/json; charset=utf-8")
	w.Header().Set("Cache-Control", "no-store")
	enc := json.NewEncoder(w)
	if err := enc.Encode(v); err != nil {
		http.Error(w, err.Error(), http.StatusInternalServerError)
	}
}

func writeErr(w http.ResponseWriter, err error) {
	w.Header().Set("Content-Type", "application/json; charset=utf-8")
	w.WriteHeader(http.StatusBadRequest)
	_ = json.NewEncoder(w).Encode(map[string]string{"error": err.Error()})
}

// currentRepo 取当前打开的仓库。
func (s *Server) currentRepo() (*git.Repo, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	if s.repo == nil {
		return nil, fmt.Errorf("no repository is open")
	}
	return s.repo, nil
}

// splitRefs 把逗号分隔的 ref 列表拆开。
func splitRefs(v string) []string {
	if strings.TrimSpace(v) == "" {
		return nil
	}
	var out []string
	for _, p := range strings.Split(v, ",") {
		if p = strings.TrimSpace(p); p != "" && !isOptionLike(p) {
			out = append(out, p)
		}
	}
	return out
}

// isOptionLike 判断一个值会不会被 git 当成命令行选项。
//
// 分支名、提交号这些参数最终原样交给 git，如果允许 "-" 开头，
// 传个 "--upload-pack=..." 之类进来就变成了执行任意命令。
func isOptionLike(v string) bool {
	return strings.HasPrefix(strings.TrimSpace(v), "-")
}

// checkArgs 校验一批要传给 git 的参数值。
func checkArgs(vals ...string) error {
	for _, v := range vals {
		if isOptionLike(v) {
			return fmt.Errorf("argument must not start with '-': %q", v)
		}
	}
	return nil
}
