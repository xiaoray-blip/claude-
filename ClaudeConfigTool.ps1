# =====================================================================
#  Claude Code 可视化配置工具  (Windows / PowerShell + WinForms)
#  - 可视化编辑多套 Claude Code 配置
#  - 一键把"启动按钮"发送到桌面
#  - 自动适配环境（运行时定位 claude，缺失给出安装指引）
#  - 整个文件夹可拷贝到任意 Windows 电脑使用
# =====================================================================

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
[System.Windows.Forms.Application]::EnableVisualStyles()

# ---------- 路径 ----------
if ($env:CLAUDE_TOOL_DIR) {
    $Root = $env:CLAUDE_TOOL_DIR
} elseif ($PSScriptRoot) {
    $Root = $PSScriptRoot
} elseif ($MyInvocation.MyCommand.Path) {
    $Root = Split-Path -Parent $MyInvocation.MyCommand.Path
} else {
    $Root = (Get-Location).Path
}
$Root = $Root.TrimEnd('\')
$DataDir     = Join-Path $Root 'data'
$LauncherDir = Join-Path $Root 'launchers'
$ConfigPath  = Join-Path $DataDir 'profiles.json'
foreach ($d in @($DataDir, $LauncherDir)) {
    if (-not (Test-Path $d)) { New-Item -ItemType Directory -Path $d -Force | Out-Null }
}

# ---------- 全局状态 ----------
$script:profiles = @()
$script:current  = -1
$script:loading  = $false

# =====================================================================
#  数据相关函数
# =====================================================================
function New-Profile {
    param([string]$Name = '新配置')
    [pscustomobject]@{
        Name      = $Name
        BaseUrl   = ''
        AuthType  = 'Auth Token'
        Key       = ''
        Model     = ''
        FastModel = ''
        WorkDir   = ''
        ExtraEnv  = ''
    }
}

function ConvertTo-NormalizedProfile {
    param($p)
    $get = {
        param($obj, $name, $def)
        if ($obj.PSObject.Properties.Name -contains $name -and $null -ne $obj.$name) { $obj.$name } else { $def }
    }
    [pscustomobject]@{
        Name      = & $get $p 'Name'      '未命名'
        BaseUrl   = & $get $p 'BaseUrl'   ''
        AuthType  = & $get $p 'AuthType'  'Auth Token'
        Key       = & $get $p 'Key'       ''
        Model     = & $get $p 'Model'     ''
        FastModel = & $get $p 'FastModel' ''
        WorkDir   = & $get $p 'WorkDir'   ''
        ExtraEnv  = & $get $p 'ExtraEnv'  ''
    }
}

function Load-Profiles {
    if (Test-Path $ConfigPath) {
        try {
            $raw = Get-Content -Path $ConfigPath -Raw -Encoding UTF8
            if ($raw.Trim()) {
                $data = $raw | ConvertFrom-Json
                $script:profiles = @($data) | ForEach-Object { ConvertTo-NormalizedProfile $_ }
            }
        } catch {
            [System.Windows.Forms.MessageBox]::Show("读取配置文件失败，将使用默认配置。`n$($_.Exception.Message)", "提示") | Out-Null
        }
    }
    if (-not $script:profiles -or $script:profiles.Count -eq 0) {
        # 首次运行：预置一条 CC Switch 代理示例
        $sample = New-Profile -Name 'CC Switch 代理'
        $sample.BaseUrl  = 'http://127.0.0.1:15721'
        $sample.AuthType = 'Auth Token'
        $sample.Key      = 'PROXY_MANAGED'
        $script:profiles = @($sample)
    }
}

function Save-Profiles {
    try {
        $json = ConvertTo-Json @($script:profiles) -Depth 6
        # 单条对象时 ConvertTo-Json 不会输出数组，强制包成数组
        if ($script:profiles.Count -eq 1) { $json = "[`n$json`n]" -replace '^\[\s*\[', '[' }
        Set-Content -Path $ConfigPath -Value $json -Encoding UTF8
        return $true
    } catch {
        [System.Windows.Forms.MessageBox]::Show("保存失败：$($_.Exception.Message)", "错误") | Out-Null
        return $false
    }
}

function Get-SafeName {
    param([string]$Name)
    $invalid = [System.IO.Path]::GetInvalidFileNameChars() -join ''
    $pattern = "[{0}]" -f [Regex]::Escape($invalid)
    $safe = ($Name -replace $pattern, '_').Trim()
    if (-not $safe) { $safe = 'profile' }
    return $safe
}

# =====================================================================
#  生成启动脚本 (.cmd) —— 自动适配环境
# =====================================================================
function New-LauncherCmd {
    param($prof)
    $safe    = Get-SafeName $prof.Name
    $cmdPath = Join-Path $LauncherDir "$safe.cmd"
    $L = New-Object System.Collections.Generic.List[string]

    $L.Add('@echo off')
    $L.Add('title Claude - ' + $prof.Name)
    $L.Add('setlocal')
    $L.Add('')
    $L.Add('REM ============================================================')
    $L.Add('REM  本文件由「Claude 配置工具」自动生成，请勿手动修改。')
    $L.Add('REM  配置名称: ' + $prof.Name)
    $L.Add('REM ============================================================')
    $L.Add('')

    if ($prof.BaseUrl) { $L.Add('set "ANTHROPIC_BASE_URL=' + $prof.BaseUrl + '"') }
    if ($prof.Key) {
        if ($prof.AuthType -eq 'API Key') {
            $L.Add('set "ANTHROPIC_API_KEY=' + $prof.Key + '"')
        } else {
            $L.Add('set "ANTHROPIC_AUTH_TOKEN=' + $prof.Key + '"')
        }
    }
    if ($prof.Model)     { $L.Add('set "ANTHROPIC_MODEL=' + $prof.Model + '"') }
    if ($prof.FastModel) { $L.Add('set "ANTHROPIC_SMALL_FAST_MODEL=' + $prof.FastModel + '"') }

    if ($prof.ExtraEnv) {
        foreach ($line in ($prof.ExtraEnv -split "`r?`n")) {
            $t = $line.Trim()
            if ($t -and $t.Contains('=') -and -not $t.StartsWith('#')) {
                $L.Add('set "' + $t + '"')
            }
        }
    }
    $L.Add('')

    if ($prof.WorkDir) {
        $L.Add('cd /d "' + $prof.WorkDir + '"')
    } else {
        $L.Add('cd /d "%USERPROFILE%"')
    }
    $L.Add('')

    # ---- 自动定位 claude（换电脑也能找到） ----
    $L.Add('REM ---- locate claude (auto-adapt) ----')
    $L.Add('set "CLAUDE_CMD="')
    $L.Add('for /f "delims=" %%i in (' + "'where claude 2^>nul'" + ') do if not defined CLAUDE_CMD set "CLAUDE_CMD=%%i"')
    $L.Add('if not defined CLAUDE_CMD if exist "%APPDATA%\npm\claude.cmd" set "CLAUDE_CMD=%APPDATA%\npm\claude.cmd"')
    $L.Add('if not defined CLAUDE_CMD if exist "%LOCALAPPDATA%\npm\claude.cmd" set "CLAUDE_CMD=%LOCALAPPDATA%\npm\claude.cmd"')
    $L.Add('if not defined CLAUDE_CMD if exist "%ProgramFiles%\nodejs\claude.cmd" set "CLAUDE_CMD=%ProgramFiles%\nodejs\claude.cmd"')
    $L.Add('')
    $L.Add('if not defined CLAUDE_CMD (')
    $L.Add('  echo.')
    $L.Add('  echo [ERROR] "claude" command not found / 未找到 claude 命令。')
    $L.Add('  echo Please install Node.js, then run:')
    $L.Add('  echo     npm install -g @anthropic-ai/claude-code')
    $L.Add('  echo.')
    $L.Add('  pause')
    $L.Add('  exit /b 1')
    $L.Add(')')
    $L.Add('')
    $L.Add('"%CLAUDE_CMD%" %*')

    # 用系统 ANSI 编码写入，cmd 默认代码页可正确显示中文
    $content = ($L -join "`r`n")
    [System.IO.File]::WriteAllText($cmdPath, $content, [System.Text.Encoding]::Default)
    return $cmdPath
}

# =====================================================================
#  发送到桌面（快捷方式）
# =====================================================================
function New-DesktopShortcut {
    param($prof, $cmdPath)
    $desktop = [Environment]::GetFolderPath('Desktop')
    $lnk = Join-Path $desktop ("Claude - " + (Get-SafeName $prof.Name) + ".lnk")
    $ws  = New-Object -ComObject WScript.Shell
    $sc  = $ws.CreateShortcut($lnk)
    $sc.TargetPath = $cmdPath
    if ($prof.WorkDir) { $sc.WorkingDirectory = $prof.WorkDir } else { $sc.WorkingDirectory = $env:USERPROFILE }
    $sc.IconLocation = "$env:SystemRoot\System32\cmd.exe,0"
    $sc.Description  = "启动 Claude Code - " + $prof.Name
    $sc.Save()
    return $lnk
}

# =====================================================================
#  环境检测
# =====================================================================
function Get-CmdPath {
    param([string]$name)
    $c = Get-Command $name -ErrorAction SilentlyContinue
    if ($c) { return $c.Source }
    return $null
}

function Test-Environment {
    $node   = Get-CmdPath 'node'
    $npm    = Get-CmdPath 'npm'
    $claude = Get-CmdPath 'claude'
    if (-not $claude) {
        foreach ($p in @("$env:APPDATA\npm\claude.cmd", "$env:LOCALAPPDATA\npm\claude.cmd")) {
            if (Test-Path $p) { $claude = $p; break }
        }
    }
    $sb = New-Object System.Text.StringBuilder
    [void]$sb.AppendLine("===== 环境检测 =====")
    [void]$sb.AppendLine("")
    if ($node)   { [void]$sb.AppendLine("[OK] Node.js : $node") } else { [void]$sb.AppendLine("[缺失] Node.js 未找到") }
    if ($npm)    { [void]$sb.AppendLine("[OK] npm     : $npm") }    else { [void]$sb.AppendLine("[缺失] npm 未找到") }
    if ($claude) { [void]$sb.AppendLine("[OK] claude  : $claude") } else { [void]$sb.AppendLine("[缺失] claude 未找到") }
    [void]$sb.AppendLine("")
    if (-not $claude) {
        [void]$sb.AppendLine("解决方法：")
        if (-not $node) { [void]$sb.AppendLine("1) 先安装 Node.js: https://nodejs.org") }
        [void]$sb.AppendLine("2) 运行: npm install -g @anthropic-ai/claude-code")
    } else {
        [void]$sb.AppendLine("环境就绪，启动按钮可以正常使用。")
    }
    [System.Windows.Forms.MessageBox]::Show($sb.ToString(), "环境检测",
        [System.Windows.Forms.MessageBoxButtons]::OK,
        [System.Windows.Forms.MessageBoxIcon]::Information) | Out-Null
}

# =====================================================================
#  测试连接
# =====================================================================
function Test-Connection {
    param($prof)
    if (-not $prof.BaseUrl) { return "未填写 API 地址（Base URL），无法测试。" }
    $url = $prof.BaseUrl.TrimEnd('/') + '/v1/messages'
    $model = if ($prof.Model) { $prof.Model } else { 'claude-3-5-haiku-20241022' }
    $headers = @{ 'anthropic-version' = '2023-06-01'; 'content-type' = 'application/json' }
    if ($prof.AuthType -eq 'API Key') {
        $headers['x-api-key'] = $prof.Key
    } else {
        $headers['Authorization'] = 'Bearer ' + $prof.Key
    }
    $body = @{ model = $model; max_tokens = 1; messages = @(@{ role = 'user'; content = 'ping' }) } | ConvertTo-Json -Depth 5
    try {
        $resp = Invoke-RestMethod -Uri $url -Method Post -Headers $headers -Body $body -TimeoutSec 20 -ErrorAction Stop
        return "连接成功！`n模型: $model`n返回类型: $($resp.type)"
    } catch {
        $msg = $_.Exception.Message
        $detail = ''
        if ($_.ErrorDetails -and $_.ErrorDetails.Message) { $detail = "`n服务器返回: " + $_.ErrorDetails.Message }
        return "连接失败：`n$msg$detail`n`n（请检查 Base URL / 密钥 / 代理是否在运行）"
    }
}

# =====================================================================
#  界面 <-> 数据
# =====================================================================
function Sync-FieldsToProfile {
    if ($script:current -lt 0 -or $script:current -ge $script:profiles.Count) { return }
    $p = $script:profiles[$script:current]
    $p.Name      = $txtName.Text.Trim()
    $p.BaseUrl   = $txtBaseUrl.Text.Trim()
    $p.AuthType  = $cmbAuth.SelectedItem
    $p.Key       = $txtKey.Text
    $p.Model     = $txtModel.Text.Trim()
    $p.FastModel = $txtFast.Text.Trim()
    $p.WorkDir   = $txtWorkDir.Text.Trim()
    $p.ExtraEnv  = $txtExtra.Text
}

function Load-ProfileToFields {
    if ($script:current -lt 0 -or $script:current -ge $script:profiles.Count) { return }
    $p = $script:profiles[$script:current]
    $script:loading = $true
    $txtName.Text    = $p.Name
    $txtBaseUrl.Text = $p.BaseUrl
    if ($cmbAuth.Items -contains $p.AuthType) { $cmbAuth.SelectedItem = $p.AuthType } else { $cmbAuth.SelectedIndex = 0 }
    $txtKey.Text     = $p.Key
    $txtModel.Text   = $p.Model
    $txtFast.Text    = $p.FastModel
    $txtWorkDir.Text = $p.WorkDir
    $txtExtra.Text   = $p.ExtraEnv
    $script:loading  = $false
}

function Refresh-List {
    param([int]$select = -1)
    $script:loading = $true
    $lst.Items.Clear()
    foreach ($p in $script:profiles) { [void]$lst.Items.Add($p.Name) }
    if ($select -ge 0 -and $select -lt $lst.Items.Count) {
        $lst.SelectedIndex = $select
        $script:current = $select
    }
    $script:loading = $false
}

function Set-Status {
    param([string]$text)
    $lblStatus.Text = $text
}

# =====================================================================
#  构建窗体
# =====================================================================
$form = New-Object System.Windows.Forms.Form
$form.Text = "Claude Code 配置工具"
$form.Size = New-Object System.Drawing.Size(790, 600)
$form.StartPosition = "CenterScreen"
$form.Font = New-Object System.Drawing.Font("Microsoft YaHei UI", 9)
$form.MinimumSize = New-Object System.Drawing.Size(790, 600)

# ---- 左侧：配置列表 ----
$lblList = New-Object System.Windows.Forms.Label
$lblList.Text = "配置列表"
$lblList.Location = New-Object System.Drawing.Point(12, 12)
$lblList.AutoSize = $true
$form.Controls.Add($lblList)

$lst = New-Object System.Windows.Forms.ListBox
$lst.Location = New-Object System.Drawing.Point(12, 36)
$lst.Size = New-Object System.Drawing.Size(200, 380)
$form.Controls.Add($lst)

$btnNew = New-Object System.Windows.Forms.Button
$btnNew.Text = "新建"
$btnNew.Location = New-Object System.Drawing.Point(12, 422)
$btnNew.Size = New-Object System.Drawing.Size(62, 30)
$form.Controls.Add($btnNew)

$btnCopy = New-Object System.Windows.Forms.Button
$btnCopy.Text = "复制"
$btnCopy.Location = New-Object System.Drawing.Point(81, 422)
$btnCopy.Size = New-Object System.Drawing.Size(62, 30)
$form.Controls.Add($btnCopy)

$btnDel = New-Object System.Windows.Forms.Button
$btnDel.Text = "删除"
$btnDel.Location = New-Object System.Drawing.Point(150, 422)
$btnDel.Size = New-Object System.Drawing.Size(62, 30)
$form.Controls.Add($btnDel)

$btnEnv = New-Object System.Windows.Forms.Button
$btnEnv.Text = "环境检测"
$btnEnv.Location = New-Object System.Drawing.Point(12, 460)
$btnEnv.Size = New-Object System.Drawing.Size(200, 30)
$form.Controls.Add($btnEnv)

# ---- 右侧：编辑区 ----
$lblX = 228
$txtX = 330
$txtW = 420
function New-FieldLabel {
    param([string]$text, [int]$y)
    $l = New-Object System.Windows.Forms.Label
    $l.Text = $text
    $l.Location = New-Object System.Drawing.Point($lblX, ($y + 3))
    $l.Size = New-Object System.Drawing.Size(100, 22)
    $form.Controls.Add($l)
    return $l
}

New-FieldLabel "配置名称" 12 | Out-Null
$txtName = New-Object System.Windows.Forms.TextBox
$txtName.Location = New-Object System.Drawing.Point($txtX, 12)
$txtName.Size = New-Object System.Drawing.Size($txtW, 24)
$form.Controls.Add($txtName)

New-FieldLabel "API 地址 (Base URL)" 44 | Out-Null
$txtBaseUrl = New-Object System.Windows.Forms.TextBox
$txtBaseUrl.Location = New-Object System.Drawing.Point($txtX, 44)
$txtBaseUrl.Size = New-Object System.Drawing.Size($txtW, 24)
$form.Controls.Add($txtBaseUrl)

New-FieldLabel "认证方式" 76 | Out-Null
$cmbAuth = New-Object System.Windows.Forms.ComboBox
$cmbAuth.DropDownStyle = 'DropDownList'
$cmbAuth.Location = New-Object System.Drawing.Point($txtX, 76)
$cmbAuth.Size = New-Object System.Drawing.Size(160, 24)
[void]$cmbAuth.Items.Add('Auth Token')
[void]$cmbAuth.Items.Add('API Key')
$cmbAuth.SelectedIndex = 0
$form.Controls.Add($cmbAuth)

$lblAuthHint = New-Object System.Windows.Forms.Label
$lblAuthHint.Text = "(代理/中转用 Auth Token，官方用 API Key)"
$lblAuthHint.Location = New-Object System.Drawing.Point(($txtX + 168), 79)
$lblAuthHint.Size = New-Object System.Drawing.Size(252, 22)
$lblAuthHint.ForeColor = [System.Drawing.Color]::Gray
$form.Controls.Add($lblAuthHint)

New-FieldLabel "密钥 / Key" 108 | Out-Null
$txtKey = New-Object System.Windows.Forms.TextBox
$txtKey.Location = New-Object System.Drawing.Point($txtX, 108)
$txtKey.Size = New-Object System.Drawing.Size(340, 24)
$txtKey.UseSystemPasswordChar = $true
$form.Controls.Add($txtKey)

$chkShow = New-Object System.Windows.Forms.CheckBox
$chkShow.Text = "显示"
$chkShow.Location = New-Object System.Drawing.Point(($txtX + 348), 108)
$chkShow.Size = New-Object System.Drawing.Size(72, 24)
$form.Controls.Add($chkShow)

New-FieldLabel "模型 (可选)" 140 | Out-Null
$txtModel = New-Object System.Windows.Forms.TextBox
$txtModel.Location = New-Object System.Drawing.Point($txtX, 140)
$txtModel.Size = New-Object System.Drawing.Size($txtW, 24)
$form.Controls.Add($txtModel)

New-FieldLabel "快速模型 (可选)" 172 | Out-Null
$txtFast = New-Object System.Windows.Forms.TextBox
$txtFast.Location = New-Object System.Drawing.Point($txtX, 172)
$txtFast.Size = New-Object System.Drawing.Size($txtW, 24)
$form.Controls.Add($txtFast)

New-FieldLabel "启动目录 (可选)" 204 | Out-Null
$txtWorkDir = New-Object System.Windows.Forms.TextBox
$txtWorkDir.Location = New-Object System.Drawing.Point($txtX, 204)
$txtWorkDir.Size = New-Object System.Drawing.Size(340, 24)
$form.Controls.Add($txtWorkDir)

$btnBrowse = New-Object System.Windows.Forms.Button
$btnBrowse.Text = "浏览"
$btnBrowse.Location = New-Object System.Drawing.Point(($txtX + 348), 203)
$btnBrowse.Size = New-Object System.Drawing.Size(72, 26)
$form.Controls.Add($btnBrowse)

New-FieldLabel "额外环境变量" 236 | Out-Null
$lblExtraHint = New-Object System.Windows.Forms.Label
$lblExtraHint.Text = "每行一个 KEY=VALUE"
$lblExtraHint.Location = New-Object System.Drawing.Point($lblX, 258)
$lblExtraHint.Size = New-Object System.Drawing.Size(100, 40)
$lblExtraHint.ForeColor = [System.Drawing.Color]::Gray
$form.Controls.Add($lblExtraHint)

$txtExtra = New-Object System.Windows.Forms.TextBox
$txtExtra.Location = New-Object System.Drawing.Point($txtX, 236)
$txtExtra.Size = New-Object System.Drawing.Size($txtW, 96)
$txtExtra.Multiline = $true
$txtExtra.ScrollBars = 'Vertical'
$form.Controls.Add($txtExtra)

# ---- 底部操作按钮 ----
$btnSave = New-Object System.Windows.Forms.Button
$btnSave.Text = "保存配置"
$btnSave.Location = New-Object System.Drawing.Point($txtX, 348)
$btnSave.Size = New-Object System.Drawing.Size(100, 34)
$form.Controls.Add($btnSave)

$btnSend = New-Object System.Windows.Forms.Button
$btnSend.Text = "发送到桌面"
$btnSend.Location = New-Object System.Drawing.Point(($txtX + 108), 348)
$btnSend.Size = New-Object System.Drawing.Size(110, 34)
$btnSend.BackColor = [System.Drawing.Color]::FromArgb(220, 237, 255)
$form.Controls.Add($btnSend)

$btnSendAll = New-Object System.Windows.Forms.Button
$btnSendAll.Text = "一键生成全部"
$btnSendAll.Location = New-Object System.Drawing.Point(($txtX + 226), 348)
$btnSendAll.Size = New-Object System.Drawing.Size(110, 34)
$form.Controls.Add($btnSendAll)

$btnTest = New-Object System.Windows.Forms.Button
$btnTest.Text = "测试连接"
$btnTest.Location = New-Object System.Drawing.Point($txtX, 388)
$btnTest.Size = New-Object System.Drawing.Size(100, 34)
$form.Controls.Add($btnTest)

# ---- 状态栏 ----
$lblStatus = New-Object System.Windows.Forms.Label
$lblStatus.Location = New-Object System.Drawing.Point(12, 510)
$lblStatus.Size = New-Object System.Drawing.Size(760, 40)
$lblStatus.ForeColor = [System.Drawing.Color]::FromArgb(0, 110, 0)
$lblStatus.Text = "就绪。配置与启动脚本都保存在工具所在文件夹，可整体拷贝到其他电脑使用。"
$form.Controls.Add($lblStatus)

# =====================================================================
#  事件
# =====================================================================
$lst.Add_SelectedIndexChanged({
    if ($script:loading) { return }
    Sync-FieldsToProfile
    $script:current = $lst.SelectedIndex
    Load-ProfileToFields
})

$chkShow.Add_CheckedChanged({
    $txtKey.UseSystemPasswordChar = -not $chkShow.Checked
})

$btnNew.Add_Click({
    Sync-FieldsToProfile
    $p = New-Profile -Name ("新配置 " + ($script:profiles.Count + 1))
    $script:profiles += $p
    Refresh-List -select ($script:profiles.Count - 1)
    Load-ProfileToFields
    Set-Status "已新建配置，记得填写后点「保存配置」。"
})

$btnCopy.Add_Click({
    if ($script:current -lt 0) { return }
    Sync-FieldsToProfile
    $src = $script:profiles[$script:current]
    $clone = ConvertTo-NormalizedProfile $src
    $clone.Name = $src.Name + " - 副本"
    $script:profiles += $clone
    Refresh-List -select ($script:profiles.Count - 1)
    Load-ProfileToFields
    Set-Status "已复制配置。"
})

$btnDel.Add_Click({
    if ($script:current -lt 0) { return }
    $name = $script:profiles[$script:current].Name
    $r = [System.Windows.Forms.MessageBox]::Show("确定删除配置「$name」吗？`n（不会删除已发送到桌面的快捷方式）", "确认删除",
        [System.Windows.Forms.MessageBoxButtons]::YesNo, [System.Windows.Forms.MessageBoxIcon]::Question)
    if ($r -ne [System.Windows.Forms.DialogResult]::Yes) { return }
    $list = [System.Collections.ArrayList]@($script:profiles)
    $list.RemoveAt($script:current)
    $script:profiles = @($list)
    if ($script:profiles.Count -eq 0) { $script:profiles = @(New-Profile -Name '新配置') }
    Save-Profiles | Out-Null
    $sel = [Math]::Min($script:current, $script:profiles.Count - 1)
    Refresh-List -select $sel
    Load-ProfileToFields
    Set-Status "已删除配置「$name」。"
})

$btnBrowse.Add_Click({
    $dlg = New-Object System.Windows.Forms.FolderBrowserDialog
    $dlg.Description = "选择启动 Claude 时的工作目录"
    if ($dlg.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) {
        $txtWorkDir.Text = $dlg.SelectedPath
    }
})

$btnSave.Add_Click({
    if (-not $txtName.Text.Trim()) {
        [System.Windows.Forms.MessageBox]::Show("请填写配置名称。", "提示") | Out-Null
        return
    }
    Sync-FieldsToProfile
    if (Save-Profiles) {
        $cur = $script:current
        Refresh-List -select $cur
        Set-Status "配置已保存到 $ConfigPath"
    }
})

$btnSend.Add_Click({
    if ($script:current -lt 0) { return }
    if (-not $txtName.Text.Trim()) {
        [System.Windows.Forms.MessageBox]::Show("请先填写配置名称。", "提示") | Out-Null
        return
    }
    Sync-FieldsToProfile
    Save-Profiles | Out-Null
    $p = $script:profiles[$script:current]
    try {
        $cmd = New-LauncherCmd $p
        $lnk = New-DesktopShortcut $p $cmd
        Refresh-List -select $script:current
        Set-Status "已发送到桌面：$lnk"
        [System.Windows.Forms.MessageBox]::Show("已在桌面创建启动按钮：`n$(Split-Path $lnk -Leaf)`n`n双击即可带此配置启动 Claude。", "完成",
            [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Information) | Out-Null
    } catch {
        [System.Windows.Forms.MessageBox]::Show("发送失败：$($_.Exception.Message)", "错误") | Out-Null
    }
})

$btnSendAll.Add_Click({
    Sync-FieldsToProfile
    Save-Profiles | Out-Null
    $ok = 0
    foreach ($p in $script:profiles) {
        if (-not $p.Name.Trim()) { continue }
        try {
            $cmd = New-LauncherCmd $p
            New-DesktopShortcut $p $cmd | Out-Null
            $ok++
        } catch { }
    }
    Set-Status "已在桌面生成 $ok 个启动按钮。"
    [System.Windows.Forms.MessageBox]::Show("已在桌面生成 $ok 个启动按钮。", "完成",
        [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Information) | Out-Null
})

$btnTest.Add_Click({
    Sync-FieldsToProfile
    if ($script:current -lt 0) { return }
    Set-Status "正在测试连接..."
    $form.Cursor = [System.Windows.Forms.Cursors]::WaitCursor
    $result = Test-Connection $script:profiles[$script:current]
    $form.Cursor = [System.Windows.Forms.Cursors]::Default
    Set-Status "测试完成。"
    [System.Windows.Forms.MessageBox]::Show($result, "测试连接") | Out-Null
})

$btnEnv.Add_Click({ Test-Environment })

# 关闭窗口时自动保存
$form.Add_FormClosing({
    Sync-FieldsToProfile
    Save-Profiles | Out-Null
})

# =====================================================================
#  启动
# =====================================================================
Load-Profiles
Refresh-List -select 0
Load-ProfileToFields
[void]$form.ShowDialog()
