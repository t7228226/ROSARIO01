# Apple SDK 遠端驗證專案

這份最小驗證程式使用 [ROSARIO01](https://github.com/t7228226/ROSARIO01) 的 GitHub 標準 macOS runner，確認 iPhoneOS SDK 可編譯程式，並記錄 Xcode、Swift 與 SDK 的實際版本。儲存庫原有的 `index.html` 保持不變。

執行結果請查看 [Apple SDK preflight](https://github.com/t7228226/ROSARIO01/actions/workflows/sdk-preflight.yml)。SDK 編譯、App 簽署與實機安裝是不同的驗證項目。

## 檔案範圍

只有以下 5 個文字檔案；不包含 Windows 安裝檔、WSL 資料、使用者帳號、裝置識別碼、Apple 帳號、密碼或憑證。

- `ios-sdk-check/.gitignore`
- `.github/workflows/sdk-preflight.yml`
- `ios-sdk-check/scripts/ios-sdk-preflight.sh`
- `ios-sdk-check/scripts/SDKProbe.swift`
- `ios-sdk-check/README.md`

本機 `macos-sdk-check/` 是這 5 個檔案的來源；上傳時只有 workflow 放在儲存庫根目錄的 `.github/workflows/`，其餘檔案放在 `ios-sdk-check/`。外層 Windows 工作區不在上傳範圍內。

## 執行方式與費用範圍

在儲存庫的 Actions 頁選擇 **Apple SDK preflight → Run workflow → main**。工作流程只接受手動 `workflow_dispatch` 啟動，使用官方列出的標準 `macos-26` runner，逾時上限 10 分鐘，重複執行會取消先前工作。

GitHub 官方說明：公開儲存庫使用標準 hosted runner 免費；私人儲存庫有額度與超額費用，larger runner 另計費。因此這份流程明確拒絕在私人儲存庫執行，不使用 larger runner，不保存 artifact 或 cache，也沒有排程。

這個免費範圍只涵蓋上述公開環境驗證專案，不表示日後任何私人 App 專案都能免費或應該公開。

## 實際驗證內容

1. 確認執行主機是 macOS，並讀取該主機既有的 iPhoneOS SDK；不下載、抽取或重新散布 Apple SDK。
2. 由 runner 內建 `swiftc` 編譯 `SDKProbe.swift`，確認 Foundation、UIKit、SwiftUI 能產生 arm64 iOS object file。
3. Xcode、Swift、SDK 的實際版本留在執行紀錄中。這些版本可能與 Windows／WSL 上的 Swift 6.4.1 不同。

此檢查不產生已簽署 App，也不證明實機安裝、免費 Personal Team 或 App Store 發布已可用。工作流程不登入 Apple、不配對裝置，也不設定簽署身分。

簽署仍須另行確認適用的 Apple 開發者註冊、憑證、provisioning profile、裝置與免費帳號能力限制，並實際測試。此流程不要求將 Apple 密碼或憑證上傳到 GitHub。

## 本機檢查與界線

Windows／WSL 可檢查 Bash 語法、工作流程結構及不含帳密的上傳清單；執行 SDK 腳本時應以結束碼 2 拒絕 Linux。這些檢查不等於遠端 Mac 的 SDK 編譯成功。

## 官方資料

- [GitHub Actions 免費與計費範圍](https://docs.github.com/en/billing/concepts/product-billing/github-actions)
- [標準 hosted runners](https://docs.github.com/en/actions/reference/runners/github-hosted-runners)
- [macOS 26 runner 預裝軟體與 SDK](https://github.com/actions/runner-images/blob/main/images/macos/macos-26-arm64-Readme.md)
- [固定使用的 checkout v7.0.1](https://github.com/actions/checkout/releases/tag/v7.0.1)
- [Apple 免費帳號與 Personal Team 限制](https://developer.apple.com/help/account/basics/about-your-developer-account)
- [Xcode／Apple SDK 授權](https://www.apple.com/legal/sla/docs/xcode.pdf)
