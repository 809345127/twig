// Package instance 管理"当前机器上跑着的那个 twig"。
//
// twig 的用法是长期开着一个实例、在界面里切换仓库，而不是每个仓库起一个进程。
// 这里把运行中实例的端口和令牌记在 ~/.twig/instance.json，
// 后续再启动 twig 时就能发现它、直接切过去，而不是又起一个。
package instance

import (
	"encoding/json"
	"fmt"
	"net/http"
	"os"
	"path/filepath"
	"strings"
	"time"
)

// Info 是一个运行中实例的落脚信息。
type Info struct {
	Port  int    `json:"port"`
	Token string `json:"token"`
	PID   int    `json:"pid"`
}

// Path 返回记录文件的位置。
func Path() string {
	home, err := os.UserHomeDir()
	if err != nil {
		return ""
	}
	return filepath.Join(home, ".twig", "instance.json")
}

// Load 读取上一次记录的实例信息。文件不存在或损坏时返回 nil。
//
// 注意：读到内容不代表那个实例还活着——进程可能被 kill -9 掉了，
// 来不及清理文件。判断是否还在跑一律用 Alive()。
func Load() *Info {
	p := Path()
	if p == "" {
		return nil
	}
	b, err := os.ReadFile(p)
	if err != nil {
		return nil
	}
	var info Info
	if err := json.Unmarshal(b, &info); err != nil || info.Port == 0 || info.Token == "" {
		return nil
	}
	return &info
}

// Save 记下当前实例的信息。
func (i *Info) Save() error {
	p := Path()
	if p == "" {
		return fmt.Errorf("cannot locate the home directory")
	}
	if err := os.MkdirAll(filepath.Dir(p), 0o755); err != nil {
		return err
	}
	b, err := json.MarshalIndent(i, "", "  ")
	if err != nil {
		return err
	}
	// 令牌在里面，只给自己读。
	return os.WriteFile(p, b, 0o600)
}

// URL 是这个实例的访问地址（带令牌）。
func (i *Info) URL() string {
	return fmt.Sprintf("http://127.0.0.1:%d/?token=%s", i.Port, i.Token)
}

// Alive 探一下这个实例还在不在。
//
// 光看端口通不通不够：别的程序也可能占着这个端口。所以要求对方
// 用我们的令牌应答 /api/ping，确认它确实是 twig 本尊。
func (i *Info) Alive() bool {
	req, err := http.NewRequest("GET", fmt.Sprintf("http://127.0.0.1:%d/api/ping", i.Port), nil)
	if err != nil {
		return false
	}
	req.Header.Set("X-Twig-Token", i.Token)

	client := &http.Client{Timeout: 1500 * time.Millisecond}
	resp, err := client.Do(req)
	if err != nil {
		return false
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		return false
	}
	var body struct {
		App string `json:"app"`
	}
	if err := json.NewDecoder(resp.Body).Decode(&body); err != nil {
		return false
	}
	return body.App == "twig"
}

// OpenRepo 让运行中的实例切换到某个仓库。
//
// 用在"在某个项目目录里又敲了一次 twig"的场景：不再起新进程，
// 而是把已经开着的那个界面切到这个仓库。
func (i *Info) OpenRepo(path string) error {
	body := strings.NewReader(fmt.Sprintf(`{"path":%q}`, path))
	req, err := http.NewRequest("POST", fmt.Sprintf("http://127.0.0.1:%d/api/open", i.Port), body)
	if err != nil {
		return err
	}
	req.Header.Set("X-Twig-Token", i.Token)
	req.Header.Set("Content-Type", "application/json")

	client := &http.Client{Timeout: 5 * time.Second}
	resp, err := client.Do(req)
	if err != nil {
		return err
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		return fmt.Errorf("the running instance refused to open %s", path)
	}
	return nil
}
