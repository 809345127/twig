// twig 是一个精简的本地 Git 图形界面。
//
// 它在本机起一个 HTTP 服务，用浏览器当界面。相比 SourceTree 多出来的能力是：
// 提交图上画哪几条分支，可以自己勾。
//
// 设计上是"长期开着一个实例、在界面里切仓库"，不是每个仓库起一个进程：
// 再次启动 twig 时，如果已经有实例在跑，就把它切到目标仓库并把浏览器带到前台。
//
// 用法：
//
//	twig                  # 打开当前目录所在的仓库
//	twig /path/to/repo
//	twig -port 7890 -no-open
//	twig -new             # 硬起一个新实例，不复用在跑的那个
package main

import (
	"embed"
	"flag"
	"fmt"
	"io/fs"
	"log"
	"net"
	"net/http"
	"os"
	"os/exec"
	"runtime"
	"strings"
	"time"

	"twig/internal/instance"
	"twig/internal/server"
)

//go:embed all:web
var webFS embed.FS

// defaultPort 是首选端口。固定下来才能在浏览器里存书签；
// 被占用时会自动退让到系统分配的空闲端口。
const defaultPort = 7890

func main() {
	port := flag.Int("port", 0, "port to listen on; 0 tries 7890 then falls back to a free one")
	noOpen := flag.Bool("no-open", false, "do not open the browser on start")
	forceNew := flag.Bool("new", false, "start a new instance even if one is already running")
	flag.Parse()

	target := repoTarget()

	// 已经有实例在跑？切过去就行，不再起第二个。
	if !*forceNew {
		if running := instance.Load(); running != nil && running.Alive() {
			handOff(running, target, *noOpen)
			return
		}
	}

	sub, err := fs.Sub(webFS, "web")
	if err != nil {
		log.Fatalf("failed to load embedded web assets: %v", err)
	}

	// 沿用上一次的令牌，这样重启之后浏览器里存的书签依然有效。
	var reuseToken string
	if prev := instance.Load(); prev != nil {
		reuseToken = prev.Token
	}
	srv := server.New(sub, reuseToken)

	openInitialRepo(srv, target)

	ln, err := listen(*port)
	if err != nil {
		log.Fatalf("failed to listen: %v", err)
	}
	addr := ln.Addr().(*net.TCPAddr)

	info := &instance.Info{Port: addr.Port, Token: srv.Token(), PID: os.Getpid()}
	// -new 起的是一次性副实例，不能抢"主实例"的登记：抢了的话主实例就失联了，
	// 下次启动会以为没人在跑，于是又起一个，书签地址也会跟着漂。
	if !*forceNew {
		if err := info.Save(); err != nil {
			fmt.Fprintf(os.Stderr, "note: cannot record the instance file: %v\n", err)
		}
		// 这个文件退出时故意不删：令牌要留给下次启动复用，浏览器里存的书签才不会失效。
		// 进程没了之后文件会变成一条过期记录，下次启动靠 Alive() 探活识别，不影响判断。
	}

	url := info.URL()
	fmt.Printf("twig is running: %s\n", url)
	fmt.Println("Press Ctrl+C to quit.")

	if !*noOpen {
		go func() {
			time.Sleep(200 * time.Millisecond)
			openBrowser(url)
		}()
	}

	httpSrv := &http.Server{
		Handler:           srv.Handler(),
		ReadHeaderTimeout: 10 * time.Second,
	}
	if err := httpSrv.Serve(ln); err != nil && err != http.ErrServerClosed {
		log.Fatal(err)
	}
}

// repoTarget 决定这次要打开哪个仓库：命令行给了就用它，否则用当前目录。
//
// 双击 App 图标启动时当前目录是 /，那不是仓库，会在后面退回到"最近打开过的"。
func repoTarget() string {
	if arg := flag.Arg(0); arg != "" {
		return arg
	}
	if cwd, err := os.Getwd(); err == nil {
		return cwd
	}
	return ""
}

// handOff 把活儿交给已经在跑的那个实例。
func handOff(running *instance.Info, target string, noOpen bool) {
	if target != "" {
		// 切不过去不算失败：多半是这个目录压根不是 git 仓库
		// （比如双击图标启动，当前目录是 /）。那就让它保持原样。
		if err := running.OpenRepo(target); err != nil && !isNotARepo(err) {
			fmt.Fprintf(os.Stderr, "note: %v\n", err)
		}
	}
	fmt.Printf("twig is already running: %s\n", running.URL())
	if !noOpen {
		openBrowser(running.URL())
	}
}

// isNotARepo 判断错误是不是"这个目录不是 git 仓库"，这种情况不用打扰用户。
func isNotARepo(err error) bool {
	return err != nil && strings.Contains(err.Error(), "refused to open")
}

// openInitialRepo 打开启动时该显示的仓库。
func openInitialRepo(srv *server.Server, target string) {
	if target != "" {
		if err := srv.OpenRepo(target); err == nil {
			return
		}
	}
	// 当前目录不是仓库（双击图标启动就是这种情况）：回到上次看的那个。
	if err := srv.OpenMostRecent(); err != nil {
		fmt.Fprintln(os.Stderr, "note: no repository opened yet — pick one in the UI")
	}
}

// listen 监听端口。want 为 0 时先试固定的 defaultPort，被占用再让系统挑一个。
func listen(want int) (net.Listener, error) {
	if want != 0 {
		return net.Listen("tcp", fmt.Sprintf("127.0.0.1:%d", want))
	}
	if ln, err := net.Listen("tcp", fmt.Sprintf("127.0.0.1:%d", defaultPort)); err == nil {
		return ln, nil
	}
	return net.Listen("tcp", "127.0.0.1:0")
}

// openBrowser 用系统默认方式打开浏览器。
func openBrowser(url string) {
	var cmd *exec.Cmd
	switch runtime.GOOS {
	case "darwin":
		cmd = exec.Command("open", url)
	case "windows":
		cmd = exec.Command("rundll32", "url.dll,FileProtocolHandler", url)
	default:
		cmd = exec.Command("xdg-open", url)
	}
	_ = cmd.Start()
}
