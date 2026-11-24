<#
.SYNOPSIS
    Antigravity Token Monitor & Live Official Quota Synchronizer
    Supports 7 Models across 2 Family Quota Pools:
    - Gemini Shared Pool: Gemini 4 Neon, Gemini 4 Carbon, Gemini 4 Hydrogen, Gemini 4 Argon, Gemini 3.8 Flash
    - Claude Independent Pool: Claude Opus 5.5, Claude Sonnet 5.5
    Fetches real-time official quotas directly from Antigravity language_server (GetUserStatus RPC)
#>

class AntigravityMonitor {
    [string]$BrainPath
    [string]$AgyDataPath
    [string]$ConfigDir
    [hashtable]$Pricing
    [string]$ActiveModel
    [string]$ActivePlan
    [string]$QuotaViewMode = "5h"
    [string]$LivePlanName = ""
    [string]$LastPbtxtModel = ""
    [string]$CurrentConvId = ""
    [string]$CurrentTranscriptPath = ""
    [long]$LastFileOffset = 0
    [datetime]$LastQuotaSync = [datetime]::MinValue
    [datetime]$LastQuotaAttempt = [datetime]::MinValue
    [hashtable]$CachedLiveQuotas = $null

    [hashtable]$ConvModelCache = @{}
    [hashtable]$TranscriptFileCache = @{}

    [hashtable]$LastTurn = @{
        Model = ""
        InvokedModelId = ""
        InputTokens = 0L
        CacheReadTokens = 0L
        OutputTokens = 0L
        TotalTokens = 0L
        CacheHitRate = 0.0
        CostUSD = 0.0
        CostCNY = 0.0
        SavingsUSD = 0.0
        SavingsCNY = 0.0
        Timestamp = [datetime]::MinValue
    }

    [hashtable]$Session = @{
        ConvId = ""
        Turns = 0
        InputTokens = 0L
        CacheReadTokens = 0L
        OutputTokens = 0L
        TotalTokens = 0L
        CurrentContext = 0L
        ContextPct = 0.0
        CostUSD = 0.0
        CostCNY = 0.0
        SavingsUSD = 0.0
        SavingsCNY = 0.0
        RawCostUSD = 0.0
        RawSavingsUSD = 0.0
    }

    [hashtable]$Today = @{
        Turns = 0
        InputTokens = 0L
        CacheReadTokens = 0L
        OutputTokens = 0L
        TotalTokens = 0L
        CostUSD = 0.0
        CostCNY = 0.0
        SavingsUSD = 0.0
        SavingsCNY = 0.0
    }

    [hashtable]$FiveHour = @{
        Turns = 0
        TotalTokens = 0L
        LimitTurns = 2500
        LimitTokens = 80000000L
        UsedPct = 0
        RemainingPct = 100
        ResetDisplay = "重置 --:--"
        RowLabel = "5H 额度"
        PoolLabel = "Gemini 共享池"
        WindowLabel = "5h 周期池"
        Disabled = $false
        IsWeekly = $false
    }

    [hashtable]$Weekly = @{
        Turns = 0
        TotalTokens = 0L
        LimitTurns = 15000
        LimitTokens = 500000000L
        UsedPct = 0
        RemainingPct = 100
        ResetDisplay = "重置 --:--"
        ShortLabel = "总额度"
        PoolLabel = "Gemini 共享池"
        WindowLabel = "总额度 (周限)"
        Disabled = $false
    }

    [System.Collections.Generic.List[hashtable]]$ModelQuotas = [System.Collections.Generic.List[hashtable]]::new()

    [hashtable]$RateLimits = @{
        CurrentRPM = 0
        MaxRPM = 15
        CurrentTPM = 0L
        MaxTPM = 1000000L
        CurrentTPS = 0.0
        MaxTPS = 16666.7
        CurrentRPD = 0
        MaxRPD = 1500
        ContextWindow = 1048576L
        ResetCountdown = "00:00:00"
    }

    [System.Collections.Generic.List[hashtable]]$RecentRequests = [System.Collections.Generic.List[hashtable]]::new()

    [bool]$SidecarOnline = $false
    [scriptblock]$OnTurnFinished = $null

    AntigravityMonitor([string]$brainPath, [string]$pricingPath, [string]$model, [string]$plan) {
        $this.BrainPath = $brainPath
        $this.AgyDataPath = Split-Path -Parent $brainPath
        $this.ConfigDir = Join-Path (Split-Path -Parent (Split-Path -Parent $pricingPath)) "config"
        $this.ActiveModel = $model
        $this.ActivePlan = $plan
        $this.LoadPricing($pricingPath)
        $detected = $this.DetectAntigravityActiveModel()
        if (![string]::IsNullOrEmpty($detected)) {
            $this.ActiveModel = $detected
            $this.LastPbtxtModel = $detected
        }
        $this.UpdateModelLimits()
        if (!$this.SyncFromSidecar()) {
            $this.ScanAllWindows()
            $this.CheckActiveConversation()
        }
    }

    [void]LoadPricing([string]$pricingPath) {
        if (Test-Path $pricingPath) {
            $json = Get-Content -LiteralPath $pricingPath -Raw -Encoding UTF8 | ConvertFrom-Json
            $defaultCtx = 1048576L
            if ($null -ne $json.context_window) { $defaultCtx = [long]$json.context_window }

            $freeRpm = 15; $freeTpm = 1000000L; $freeRpd = 1500; $freeMult = 1.0
            $tier1Rpm = 1000; $tier1Tpm = 4000000L; $tier1Rpd = 10000; $tier1Mult = 5.0
            if ($null -ne $json.limits) {
                if ($null -ne $json.limits.free) {
                    $freeRpm = [int]$json.limits.free.rpm
                    $freeTpm = [long]$json.limits.free.tpm
                    $freeRpd = [int]$json.limits.free.rpd
                    if ($null -ne $json.limits.free.quota_multiplier) { $freeMult = [double]$json.limits.free.quota_multiplier }
                }
                if ($null -ne $json.limits.tier1) {
                    $tier1Rpm = [int]$json.limits.tier1.rpm
                    $tier1Tpm = [long]$json.limits.tier1.tpm
                    $tier1Rpd = [int]$json.limits.tier1.rpd
                    if ($null -ne $json.limits.tier1.quota_multiplier) { $tier1Mult = [double]$json.limits.tier1.quota_multiplier }
                }
            }

            $modelsHash = @{}
            if ($null -ne $json.models) {
                foreach ($p in $json.models.PSObject.Properties) {
                    $k = $p.Name
                    $v = $p.Value
                    $tiersList = @()
                    if ($null -ne $v.tiers) {
                        foreach ($t in $v.tiers) {
                            $maxIn = [long]::MaxValue
                            if ($null -ne $t.maxIn) { $maxIn = [long]$t.maxIn }
                            $tiersList += @{
                                maxIn = $maxIn
                                hit = [double]$t.hit
                                miss = [double]$t.miss
                                out = [double]$t.out
                            }
                        }
                    }
                    $modelsHash[$k] = @{
                        display_name = [string]$v.display_name
                        short_name = [string]$v.short_name
                        vendor = [string]$v.vendor
                        badge = [string]$v.badge
                        quota_pool = $(if ($null -ne $v.quota_pool -and ![string]::IsNullOrEmpty([string]$v.quota_pool)) { [string]$v.quota_pool } else { $k })
                        pool_label = $(if ($null -ne $v.pool_label -and ![string]::IsNullOrEmpty([string]$v.pool_label)) { [string]$v.pool_label } else { "独立池" })
                        note = [string]$v.note
                        context_window = $(if ($null -ne $v.context_window) { [long]$v.context_window } else { $defaultCtx })
                        quota_5h_turns = $(if ($null -ne $v.quota_5h_turns) { [int]$v.quota_5h_turns } else { 1200 })
                        quota_5h_tokens = $(if ($null -ne $v.quota_5h_tokens) { [long]$v.quota_5h_tokens } else { 45000000L })
                        quota_weekly_turns = $(if ($null -ne $v.quota_weekly_turns) { [int]$v.quota_weekly_turns } else { 7000 })
                        quota_weekly_tokens = $(if ($null -ne $v.quota_weekly_tokens) { [long]$v.quota_weekly_tokens } else { 280000000L })
                        tiers = $tiersList
                    }
                }
            }

            $this.Pricing = @{
                usd_to_cny = $(if ($null -ne $json.usd_to_cny) { [double]$json.usd_to_cny } else { 7.25 })
                default_model = $(if ($null -ne $json.default_model) { [string]$json.default_model } else { "gemini-4-hydrogen" })
                context_window = $defaultCtx
                models = $modelsHash
                limits = @{
                    free = @{ rpm = $freeRpm; tpm = $freeTpm; rpd = $freeRpd; quota_multiplier = $freeMult }
                    tier1 = @{ rpm = $tier1Rpm; tpm = $tier1Tpm; rpd = $tier1Rpd; quota_multiplier = $tier1Mult }
                }
            }
        }
    }

    [void]SetModel([string]$model, [string]$plan) {
        $this.ActiveModel = $model
        $this.ActivePlan = $plan
        $this.UpdateModelLimits()
        $this.RecalculateSessionCost()
        $this.ScanAllWindows()
    }

    [void]SetQuotaViewMode([string]$mode) {
        $this.QuotaViewMode = if ($mode -eq "weekly") { "weekly" } else { "5h" }
        foreach ($mq in $this.ModelQuotas) {
            if ($mq.Disabled) { continue }
            if ($this.QuotaViewMode -eq "weekly") {
                $mq.IsWeekly = $true
                $mq.RemainingPct = [int]$mq.WeeklyRemainingPct
                $mq.ResetDisplay = [string]$mq.WeeklyReset
                $mq.WindowLabel = if ([string]$mq.WeeklyReset -like "本地估算*") { "本地估算周额" } else { "总额度 (周限)" }
            } else {
                $mq.IsWeekly = $false
                $mq.RemainingPct = [int]$mq.FiveHourRemainingPct
                $mq.ResetDisplay = [string]$mq.FiveHourReset
                $mq.WindowLabel = if ([string]$mq.FiveHourReset -like "本地估算*") { "本地估算 5h" } else { "5h 周期池" }
            }
        }
    }

    [void]UpdateModelLimits() {
        if (!$this.Pricing) { return }
        $m = $this.Pricing.models[$this.ActiveModel]
        if ($m) {
            $this.RateLimits.ContextWindow = [long]$m.context_window
        }
        $limits = $this.Pricing.limits[$this.ActivePlan]
        if ($limits) {
            $this.RateLimits.MaxRPM = [int]$limits.rpm
            $this.RateLimits.MaxTPM = [long]$limits.tpm
            $this.RateLimits.MaxTPS = [Math]::Round([double]$limits.tpm / 60.0, 1)
            $this.RateLimits.MaxRPD = [int]$limits.rpd
        }
    }

    [string]MapRawModelKey([string]$rawText) {
        if ([string]::IsNullOrWhiteSpace($rawText)) { return "" }
        $t = $rawText.ToLowerInvariant()
        if ($t -match 'model_placeholder_m532|model_placeholder_m533|model_placeholder_m534|model_placeholder_m535|model_placeholder_m537|gemini-pro-orchestrator-neon|gemini-4-neon|neon') {
            return "gemini-4-neon"
        }
        if ($t -match 'model_placeholder_m417|model_placeholder_m418|model_placeholder_m419|model_placeholder_m681|model_placeholder_m668|gemini-pro-orchestrator-argon|gemini-pro-orchestrator-g1-pro|gemini-4-argon|argon') {
            return "gemini-4-argon"
        }
        if ($t -match 'model_placeholder_m427|model_placeholder_m437|model_placeholder_m438|model_placeholder_m667|model_placeholder_m670|gemini-pro-orchestrator|orchestrator|gemini-4-carbon|carbon') {
            return "gemini-4-carbon"
        }
        if ($t -match 'model_placeholder_m525|model_placeholder_m526|model_placeholder_m527|model_placeholder_m528|model_placeholder_m669|gemini-flash-worker-agy|gemini-flash-worker|flash-worker|gemini-4-hydrogen|hydrogen') {
            return "gemini-4-hydrogen"
        }
        if ($t -match 'model_placeholder_m400|model_placeholder_m401|model_placeholder_m402|model_placeholder_m26|claude-opus|opus') {
            return "claude-opus-5-5"
        }
        if ($t -match 'model_placeholder_m403|model_placeholder_m404|model_placeholder_m405|claude-sonnet|sonnet') {
            return "claude-sonnet-5-5"
        }
        if ($t -match 'model_placeholder_m318|model_placeholder_m319|model_placeholder_m320|model_placeholder_m322|gemini-3\.8-flash-tiered|gemini-3\.8-flash-n|gemini-3\.8-flash|flash') {
            return "gemini-3.8-flash"
        }
        return ""
    }

    [string]FormatCountdown([double]$secsLeft) {
        if ($secsLeft -le 0) { return "已就绪" }
        $totalMins = [int][Math]::Floor($secsLeft / 60.0)
        $hours = [int][Math]::Floor($totalMins / 60.0)
        $mins = $totalMins % 60
        if ($hours -ge 24) {
            $days = [int][Math]::Floor($hours / 24.0)
            $remH = $hours % 24
            return "${days}d${remH}h"
        }
        if ($hours -gt 0) {
            return "${hours}h" + $mins.ToString("00") + "m"
        }
        return "$([Math]::Max(1, $mins))m"
    }

    [string]DetectAntigravityActiveModel() {
        $pbtxtPath = Join-Path $this.AgyDataPath "antigravity_state.pbtxt"
        if (Test-Path $pbtxtPath) {
            try {
                $content = Get-Content -LiteralPath $pbtxtPath -Raw -Encoding UTF8
                if ($content -match 'last_selected_agent_model:\s*(\S+)') {
                    $raw = $Matches[1].Trim('"'' ')
                    $mapped = $this.MapRawModelKey($raw)
                    if (![string]::IsNullOrEmpty($mapped)) {
                        return $mapped
                    }
                }
            } catch {}
        }
        if ([string]::IsNullOrEmpty($this.ActiveModel) -or !$this.Pricing.models.ContainsKey($this.ActiveModel)) {
            return "gemini-4-hydrogen"
        }
        return $this.ActiveModel
    }

    [bool]TestLoopbackPort([int]$port, [int]$timeoutMs) {
        if ($port -le 0) { return $false }
        $tcp = $null
        try {
            $tcp = [System.Net.Sockets.TcpClient]::new()
            $iar = $tcp.BeginConnect("127.0.0.1", $port, $null, $null)
            $ok = $iar.AsyncWaitHandle.WaitOne($timeoutMs, $false)
            if (!$ok) { return $false }
            $tcp.EndConnect($iar)
            return $true
        } catch {
            return $false
        } finally {
            if ($null -ne $tcp) { try { $tcp.Close() } catch {} }
        }
    }

    [object]CallLanguageServerRpc([int]$port, [string]$csrf, [string]$sch, [string]$rpcName) {
        try {
            $url = "${sch}://127.0.0.1:${port}/exa.language_server_pb.LanguageServerService/${rpcName}"
            $req = [System.Net.HttpWebRequest]::Create($url)
            $req.Proxy = $null
            $req.Method = "POST"
            $req.ContentType = "application/json"
            $req.Timeout = 500
            $req.ReadWriteTimeout = 500
            $req.Headers.Add("Connect-Protocol-Version", "1")
            $req.Headers.Add("x-codeium-csrf-token", $csrf)
            $bytes = [System.Text.Encoding]::UTF8.GetBytes("{}")
            $req.ContentLength = $bytes.Length
            $reqStream = $req.GetRequestStream()
            $reqStream.Write($bytes, 0, $bytes.Length)
            $reqStream.Close()
            $resp = $req.GetResponse()
            $reader = [System.IO.StreamReader]::new($resp.GetResponseStream(), [System.Text.Encoding]::UTF8)
            $jsonStr = $reader.ReadToEnd()
            $reader.Close()
            $resp.Close()
            if (![string]::IsNullOrWhiteSpace($jsonStr)) {
                return ($jsonStr | ConvertFrom-Json)
            }
        } catch {}
        return $null
    }

    [hashtable]CallLanguageServerGetUserStatus([int]$port, [string]$csrf, [string]$preferredScheme) {
        if (!$this.TestLoopbackPort($port, 80)) { return $null }
        $schemes = @()
        if ($preferredScheme -in @("https", "http")) { $schemes += $preferredScheme }
        foreach ($s in @("https", "http")) {
            if ($s -notin $schemes) { $schemes += $s }
        }
        try {
            [System.Net.ServicePointManager]::SecurityProtocol = [System.Net.SecurityProtocolType]::Tls12 -bor [System.Net.ServicePointManager]::SecurityProtocol
        } catch {}
        $prevCb = [System.Net.ServicePointManager]::ServerCertificateValidationCallback
        try {
            [System.Net.ServicePointManager]::ServerCertificateValidationCallback = { param($sender, $cert, $chain, $errors) return $true }
            foreach ($sch in $schemes) {
                $obj = $this.CallLanguageServerRpc($port, $csrf, $sch, "GetUserStatus")
                if ($null -ne $obj -and $null -ne $obj.userStatus) {
                    $summaryObj = $this.CallLanguageServerRpc($port, $csrf, $sch, "RetrieveUserQuotaSummary")
                    return @{ Data = $obj; SummaryData = $summaryObj; Scheme = $sch }
                }
            }
        } finally {
            [System.Net.ServicePointManager]::ServerCertificateValidationCallback = $prevCb
        }
        return $null
    }

    [hashtable]ParseResetMeta([string]$rtime, [datetime]$nowUtc, [Nullable[bool]]$isWeeklyHint) {
        $resetUtc = $nowUtc.AddHours(5)
        $hasReset = $false
        $isWeekly = if ($null -ne $isWeeklyHint) { [bool]$isWeeklyHint } else { $false }
        if (![string]::IsNullOrEmpty($rtime)) {
            $parsedDt = $nowUtc
            if ([datetime]::TryParse($rtime, [ref]$parsedDt)) {
                $resetUtc = $parsedDt.ToUniversalTime()
                $hasReset = $true
            }
        }
        $secsLeft = ($resetUtc - $nowUtc).TotalSeconds
        $hoursLeft = $secsLeft / 3600.0
        if ($null -eq $isWeeklyHint -and $hoursLeft -gt 24.0) {
            $isWeekly = $true
        }
        $localReset = $resetUtc.ToLocalTime()
        $cd = $this.FormatCountdown($secsLeft)
        $resetDisp = if (!$hasReset) {
            "实时同步"
        } elseif ($secsLeft -le 0) {
            "已就绪 · 随时重置"
        } elseif ($isWeekly) {
            "重置 " + $localReset.ToString("MM-dd HH:mm") + " ($cd)"
        } else {
            "重置 " + $localReset.ToString("HH:mm:ss") + " ($cd)"
        }
        return @{
            IsWeekly = $isWeekly
            ResetDisplay = $resetDisp
            HoursLeft = $hoursLeft
            HasReset = $hasReset
        }
    }

    [hashtable]ParseQuotaSummaryGroups($summaryObj, [datetime]$nowUtc) {
        $poolSummary = @{}
        if ($null -eq $summaryObj -or $null -eq $summaryObj.response -or $null -eq $summaryObj.response.groups) {
            return $poolSummary
        }
        foreach ($g in $summaryObj.response.groups) {
            $gName = [string]$g.displayName
            $gDesc = [string]$g.description
            $buckets = @($g.buckets)
            $bIds = ($buckets | ForEach-Object { [string]$_.bucketId }) -join " "
            $sig = "$gName $gDesc $bIds".ToLowerInvariant()
            $poolKey = ""
            if ($sig -match 'gemini') {
                $poolKey = "gemini"
            } elseif ($sig -match 'claude|3p|gpt') {
                $poolKey = "claude"
            }
            if ([string]::IsNullOrEmpty($poolKey)) { continue }

            $wins = @{}
            foreach ($b in $buckets) {
                $win = ([string]$b.window).Trim().ToLowerInvariant()
                $bid = ([string]$b.bucketId).Trim().ToLowerInvariant()
                $wKey = ""
                if ($win -eq "weekly" -or $bid.EndsWith("-weekly")) {
                    $wKey = "weekly"
                } elseif ($win -eq "5h" -or $bid.EndsWith("-5h")) {
                    $wKey = "5h"
                } else {
                    continue
                }
                $remPct = 100
                $rtime = [string]$b.resetTime
                if ($null -ne $b.remainingFraction) {
                    $remPct = [int][Math]::Round([double]$b.remainingFraction * 100.0)
                } elseif (![string]::IsNullOrEmpty($rtime)) {
                    $remPct = 0
                }
                $remPct = [Math]::Min(100, [Math]::Max(0, $remPct))
                $rm = $this.ParseResetMeta($rtime, $nowUtc, ($wKey -eq "weekly"))
                $wins[$wKey] = @{
                    Pct = $remPct
                    ResetDisplay = $rm.ResetDisplay
                }
            }
            if ($wins.Count -gt 0) {
                $poolSummary[$poolKey] = $wins
            }
        }
        return $poolSummary
    }

    [hashtable]FetchLiveAntigravityQuotas() {
        $nowUtc = [datetime]::UtcNow
        if ($null -ne $this.CachedLiveQuotas -and ($nowUtc - $this.LastQuotaSync).TotalSeconds -lt 10) {
            return $this.CachedLiveQuotas
        }
        if ($null -eq $this.CachedLiveQuotas -and ($nowUtc - $this.LastQuotaAttempt).TotalSeconds -lt 30) {
            return $null
        }
        $this.LastQuotaAttempt = $nowUtc

        $bridgePath = Join-Path $this.ConfigDir "ls_bridge.json"
        $port = 0
        $csrf = ""
        $scheme = ""
        $bridgePid = 0

        if (Test-Path $bridgePath) {
            try {
                $b = Get-Content -LiteralPath $bridgePath -Raw -Encoding UTF8 | ConvertFrom-Json
                if ($null -ne $b.port -and $null -ne $b.csrf) {
                    $port = [int]$b.port
                    $csrf = [string]$b.csrf
                    if ($null -ne $b.scheme) { $scheme = [string]$b.scheme }
                    if ($null -ne $b.pid) { $bridgePid = [int]$b.pid }
                }
            } catch {}
        }

        if ($bridgePid -gt 0) {
            $procAlive = $false
            try {
                $bp = [System.Diagnostics.Process]::GetProcessById($bridgePid)
                $procAlive = !$bp.HasExited
                $bp.Dispose()
            } catch {}
            if (!$procAlive) {
                $port = 0
            }
        }

        $rpcHit = $null
        if ($port -gt 0 -and ![string]::IsNullOrEmpty($csrf)) {
            $rpcHit = $this.CallLanguageServerGetUserStatus($port, $csrf, $scheme)
        }

        if ($null -eq $rpcHit) {
            try {
                $lsProcs = @(Get-CimInstance Win32_Process -Filter "Name LIKE 'language_server%'" -ErrorAction SilentlyContinue)
                foreach ($p in $lsProcs) {
                    $cmd = [string]$p.CommandLine
                    if ($cmd -match '--csrf_token[=\s]+([a-fA-F0-9\-]+)') {
                        $candCsrf = $Matches[1].Trim('"'' ')
                        $conns = @(Get-NetTCPConnection -State Listen -OwningProcess $p.ProcessId -ErrorAction SilentlyContinue | Sort-Object LocalPort)
                        foreach ($c in $conns) {
                            $candPort = [int]$c.LocalPort
                            $rpcHit = $this.CallLanguageServerGetUserStatus($candPort, $candCsrf, "")
                            if ($null -ne $rpcHit) {
                                $port = $candPort
                                $csrf = $candCsrf
                                $scheme = [string]$rpcHit.Scheme
                                try {
                                    if (!(Test-Path $this.ConfigDir)) { New-Item -ItemType Directory -Path $this.ConfigDir -Force | Out-Null }
                                    @{ scheme = $scheme; port = $port; csrf = $csrf; pid = $p.ProcessId } | ConvertTo-Json | Set-Content -LiteralPath $bridgePath -Encoding UTF8 -Force
                                } catch {}
                                break
                            }
                        }
                    }
                    if ($null -ne $rpcHit) { break }
                }
            } catch {}
        }

        if ($null -eq $rpcHit -or $null -eq $rpcHit.Data -or $null -eq $rpcHit.Data.userStatus) {
            $this.LastQuotaSync = $nowUtc
            return $this.CachedLiveQuotas
        }

        $respObj = $rpcHit.Data
        $result = @{
            PlanName = "Pro"
            Models = @{}
        }

        try {
            if ($null -ne $respObj.userStatus.planStatus -and $null -ne $respObj.userStatus.planStatus.planInfo -and $null -ne $respObj.userStatus.planStatus.planInfo.planName) {
                $result.PlanName = [string]$respObj.userStatus.planStatus.planInfo.planName
            }
            $this.LivePlanName = $result.PlanName
            $poolSummary = $this.ParseQuotaSummaryGroups($rpcHit.SummaryData, $nowUtc)
            $configs = $respObj.userStatus.cascadeModelConfigData.clientModelConfigs
            foreach ($cfg in $configs) {
                $label = [string]$cfg.label
                $mid = [string]$cfg.modelId
                $ph = ""
                if ($null -ne $cfg.modelOrAlias -and $null -ne $cfg.modelOrAlias.model) {
                    $ph = [string]$cfg.modelOrAlias.model
                }
                $targetKey = $this.MapRawModelKey("$ph $label $mid")
                if ([string]::IsNullOrEmpty($targetKey)) { continue }

                $isDisabled = ($null -ne $cfg.disabled -and [bool]$cfg.disabled)
                $tagTitle = if ($null -ne $cfg.tagTitle) { [string]$cfg.tagTitle } else { "" }
                $q = $cfg.quotaInfo
                $hasQuotaFields = ($null -ne $q) -and ($null -ne $q.remainingFraction -or ($null -ne $q.resetTime -and ![string]::IsNullOrEmpty([string]$q.resetTime)))

                if ($isDisabled -and !$hasQuotaFields) {
                    $result.Models[$targetKey] = @{
                        Disabled = $true
                        IsWeeklyWindow = $false
                        RemainingPct = 0
                        UsedPct = 100
                        WindowLabel = $(if ($tagTitle) { $tagTitle } else { "Unavailable" })
                        ResetDisplay = "暂不可用 · 需 Ultra"
                        FiveHourRemainingPct = 0
                        FiveHourReset = "暂不可用 · 需 Ultra"
                        HasLive5h = $false
                        WeeklyRemainingPct = 0
                        WeeklyReset = "需 Ultra 订阅"
                        HasLiveWeekly = $false
                    }
                    continue
                }

                $remPct = 100
                $rtime = ""
                if ($null -ne $q) {
                    if ($null -ne $q.resetTime) { $rtime = [string]$q.resetTime }
                    if ($null -ne $q.remainingFraction) {
                        $remPct = [int][Math]::Round([double]$q.remainingFraction * 100.0)
                    } elseif (![string]::IsNullOrEmpty($rtime)) {
                        $remPct = 0
                    }
                }
                $remPct = [Math]::Min(100, [Math]::Max(0, $remPct))
                $rm = $this.ParseResetMeta($rtime, $nowUtc, $null)
                $isWeeklyWindow = [bool]$rm.IsWeekly
                $resetDisp = [string]$rm.ResetDisplay
                $winLabel = if ($isWeeklyWindow) { "总额度 (周限)" } else { "5h 周期池" }

                $rem5h = $remPct
                $res5h = if (!$isWeeklyWindow) { $resetDisp } else { "实时同步" }
                $hasLive5h = !$isWeeklyWindow
                $remWk = $remPct
                $resWk = if ($isWeeklyWindow) { $resetDisp } else { "实时同步" }
                $hasLiveWk = $isWeeklyWindow

                $pName = if ($this.Pricing -and $this.Pricing.models.ContainsKey($targetKey)) { [string]$this.Pricing.models[$targetKey].quota_pool } elseif ($targetKey -like "claude*") { "claude" } else { "gemini" }
                if (!$isDisabled -and $poolSummary.ContainsKey($pName)) {
                    $ps = $poolSummary[$pName]
                    if ($ps.ContainsKey("5h")) {
                        $rem5h = [int]$ps["5h"].Pct
                        $res5h = [string]$ps["5h"].ResetDisplay
                        $hasLive5h = $true
                        if (!$isWeeklyWindow) {
                            $remPct = $rem5h
                            $resetDisp = $res5h
                        }
                    }
                    if ($ps.ContainsKey("weekly")) {
                        $remWk = [int]$ps["weekly"].Pct
                        $resWk = [string]$ps["weekly"].ResetDisplay
                        $hasLiveWk = $true
                        if ($isWeeklyWindow) {
                            $remPct = $remWk
                            $resetDisp = $resWk
                        }
                    }
                }

                if (!$result.Models.ContainsKey($targetKey) -or (!$isDisabled -and ($mid -match '-high$' -or $result.Models[$targetKey].Disabled))) {
                    $result.Models[$targetKey] = @{
                        Disabled = $isDisabled
                        RemainingPct = $remPct
                        UsedPct = (100 - $remPct)
                        ResetDisplay = $resetDisp
                        IsWeeklyWindow = $isWeeklyWindow
                        WindowLabel = $winLabel
                        HoursLeft = $rm.HoursLeft
                        FiveHourRemainingPct = $rem5h
                        FiveHourReset = $res5h
                        HasLive5h = $hasLive5h
                        WeeklyRemainingPct = $remWk
                        WeeklyReset = $resWk
                        HasLiveWeekly = $hasLiveWk
                    }
                }
            }

            foreach ($pair in @(
                @("gemini-4-neon", "gemini-4-carbon"),
                @("gemini-4-neon", "gemini-4-hydrogen"),
                @("gemini-4-neon", "gemini-4-argon"),
                @("gemini-4-neon", "gemini-3.8-flash"),
                @("gemini-4-hydrogen", "gemini-4-carbon"),
                @("gemini-4-hydrogen", "gemini-4-argon"),
                @("gemini-4-hydrogen", "gemini-3.8-flash"),
                @("claude-opus-5-5", "claude-sonnet-5-5")
            )) {
                $a = $pair[0]; $b = $pair[1]
                if ($result.Models.ContainsKey($a) -and !$result.Models.ContainsKey($b) -and !$result.Models[$a].Disabled) {
                    $result.Models[$b] = $result.Models[$a].Clone()
                } elseif ($result.Models.ContainsKey($b) -and !$result.Models.ContainsKey($a) -and !$result.Models[$b].Disabled) {
                    $result.Models[$a] = $result.Models[$b].Clone()
                }
            }
        } catch {}

        $this.CachedLiveQuotas = $result
        $this.LastQuotaSync = $nowUtc
        return $result
    }

    [string]GetConversationModel([string]$convId) {
        if ([string]::IsNullOrEmpty($convId)) { return $this.DetectAntigravityActiveModel() }

        $dbPath = Join-Path (Join-Path $this.AgyDataPath "conversations") "$convId.db"
        if (Test-Path $dbPath) {
            try {
                $fi = [System.IO.FileInfo]::new($dbPath)
                $sig = "$($fi.Length)|$($fi.LastWriteTimeUtc.Ticks)"
                if ($this.ConvModelCache.ContainsKey($convId)) {
                    $entry = $this.ConvModelCache[$convId]
                    if ($entry -is [hashtable] -and $entry.Sig -eq $sig -and ![string]::IsNullOrEmpty([string]$entry.Model)) {
                        return [string]$entry.Model
                    }
                }

                $fs = [System.IO.FileStream]::new($dbPath, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::ReadWrite)
                $chunkLen = [int][Math]::Min(262144L, $fs.Length)
                $buf = [byte[]]::new($chunkLen)
                if ($fs.Length -gt $chunkLen) {
                    $fs.Seek($fs.Length - $chunkLen, [System.IO.SeekOrigin]::Begin) | Out-Null
                }
                $read = $fs.Read($buf, 0, $chunkLen)
                $fs.Dispose()

                $latin1 = [System.Text.Encoding]::GetEncoding("ISO-8859-1").GetString($buf, 0, $read)
                $pattern = '((?:gemini|claude|gpt)-[a-z0-9.\-]+)[\s\S]{1,260}?model_enum[^\w]*(MODEL_[A-Z0-9_]+)|model_enum[^\w]*(MODEL_[A-Z0-9_]+)'
                $matches = [regex]::Matches($latin1, $pattern, [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)
                $mapped = ""
                for ($i = $matches.Count - 1; $i -ge 0; $i--) {
                    $m = $matches[$i]
                    $rawId = $m.Groups[1].Value
                    $enumStr = if (![string]::IsNullOrEmpty($m.Groups[2].Value)) { $m.Groups[2].Value } else { $m.Groups[3].Value }
                    $mapped = $this.MapRawModelKey("$rawId $enumStr")
                    if (![string]::IsNullOrEmpty($mapped)) { break }
                }
                if (![string]::IsNullOrEmpty($mapped)) {
                    $this.ConvModelCache[$convId] = @{ Sig = $sig; Model = $mapped }
                    return $mapped
                }
            } catch {}
        }

        return $this.DetectAntigravityActiveModel()
    }

    [hashtable]CalculateCost([long]$inputTokens, [long]$cacheTokens, [long]$outputTokens, [string]$modelKey) {
        if ([string]::IsNullOrEmpty($modelKey) -or !$this.Pricing.models.ContainsKey($modelKey)) {
            $modelKey = $this.ActiveModel
        }
        $m = $this.Pricing.models[$modelKey]
        $rate = [double]$this.Pricing.usd_to_cny

        $totalInput = $inputTokens + $cacheTokens
        $hitRate = 0.0
        if ($totalInput -gt 0) {
            $hitRate = [double]$cacheTokens / [double]$totalInput
        }

        $matchedTier = $m.tiers[0]
        foreach ($t in $m.tiers) {
            if ($totalInput -le $t.maxIn) {
                $matchedTier = $t
                break
            }
        }

        $costUSD = (($cacheTokens / 1000000.0) * $matchedTier.hit) +
                   (($inputTokens / 1000000.0) * $matchedTier.miss) +
                   (($outputTokens / 1000000.0) * $matchedTier.out)

        $savingsUSD = ($cacheTokens / 1000000.0) * ($matchedTier.miss - $matchedTier.hit)

        return @{
            CostUSD = [Math]::Round($costUSD, 6)
            CostCNY = [Math]::Round($costUSD * $rate, 4)
            SavingsUSD = [Math]::Round($savingsUSD, 6)
            SavingsCNY = [Math]::Round($savingsUSD * $rate, 4)
            RawCostUSD = $costUSD
            RawSavingsUSD = $savingsUSD
            HitRate = [Math]::Round($hitRate * 100.0, 1)
        }
    }

    [void]CheckActiveConversation() {
        if (!(Test-Path $this.BrainPath)) { return }

        $dirs = Get-ChildItem -Path $this.BrainPath -Directory -ErrorAction SilentlyContinue |
                Sort-Object LastWriteTime -Descending

        if ($dirs.Count -gt 0) {
            $newest = $dirs[0]
            if ($newest.Name -ne $this.CurrentConvId) {
                $this.CurrentConvId = $newest.Name
                $this.CurrentTranscriptPath = Join-Path $newest.FullName ".system_generated\logs\transcript.jsonl"
                $this.LastFileOffset = 0
                $this.ResetSessionStats($this.CurrentConvId)
                $this.ReadEntireCurrentTranscript()
            }
        }
    }

    [void]ResetSessionStats([string]$convId) {
        $this.Session.ConvId = $convId
        $this.Session.Turns = 0
        $this.Session.InputTokens = 0L
        $this.Session.CacheReadTokens = 0L
        $this.Session.OutputTokens = 0L
        $this.Session.TotalTokens = 0L
        $this.Session.CurrentContext = 0L
        $this.Session.ContextPct = 0.0
        $this.Session.CostUSD = 0.0
        $this.Session.CostCNY = 0.0
        $this.Session.SavingsUSD = 0.0
        $this.Session.SavingsCNY = 0.0
        $this.Session.RawCostUSD = 0.0
        $this.Session.RawSavingsUSD = 0.0
    }

    [void]ReadEntireCurrentTranscript() {
        if (!(Test-Path $this.CurrentTranscriptPath)) { return }
        try {
            $lines = Get-Content -LiteralPath $this.CurrentTranscriptPath -Encoding UTF8 -ErrorAction SilentlyContinue
            $fi = [System.IO.FileInfo]::new($this.CurrentTranscriptPath)
            $this.LastFileOffset = $fi.Length

            foreach ($line in $lines) {
                if ([string]::IsNullOrWhiteSpace($line)) { continue }
                if ($line.IndexOf('"input_tokens"') -ge 0) {
                    $d = $line | ConvertFrom-Json
                    if ($null -ne $d.input_tokens) {
                        $this.ProcessStep($d, $false)
                    }
                }
            }
            $this.RecalculateSessionCost()
        } catch {}
    }

    [bool]SyncFromSidecar() {
        try {
            $scPort = 54716
            $scToken = ""
            foreach ($candInfo in @(
                (Join-Path $this.AgyDataPath "sidecar_data\gemini-hakimi-widget\hakimi_panel\data\server_info.json"),
                (Join-Path $this.AgyDataPath "sidecar_data\hakimi_panel\data\server_info.json")
            )) {
                if (Test-Path $candInfo) {
                    try {
                        $sInfo = Get-Content -LiteralPath $candInfo -Raw -Encoding UTF8 | ConvertFrom-Json
                        if ($null -ne $sInfo.port -and [int]$sInfo.port -gt 0) {
                            $scPort = [int]$sInfo.port
                        }
                        if ($null -ne $sInfo.token) {
                            $scToken = [string]$sInfo.token
                        }
                        break
                    } catch {}
                }
            }
            $url = "http://127.0.0.1:${scPort}/api/stats"
            $req = [System.Net.WebRequest]::CreateHttp($url)
            $req.Proxy = $null
            $req.Timeout = 1500
            $req.Method = "GET"
            if (![string]::IsNullOrEmpty($scToken)) {
                $req.Headers.Add("X-Sidecar-Token", $scToken)
            }
            $resp = $req.GetResponse()
            $stream = $resp.GetResponseStream()
            $reader = [System.IO.StreamReader]::new($stream, [System.Text.Encoding]::UTF8)
            $jsonStr = $reader.ReadToEnd()
            $reader.Dispose()
            $stream.Dispose()
            $resp.Dispose()

            $data = $jsonStr | ConvertFrom-Json
            if ($null -eq $data -or !$data.ok) { return $false }

            # 0. Sync ActiveModel / Plan / QuotaViewMode from Sidecar SSOT
            if ($data.config) {
                $scModel = [string]$data.config.active_model
                $scPlan = [string]$data.config.active_plan
                $scMode = if ([string]$data.config.quota_view_mode -eq "weekly") { "weekly" } else { "5h" }
                $this.QuotaViewMode = $scMode
                if (![string]::IsNullOrEmpty($scModel) -and $this.Pricing.models.ContainsKey($scModel) -and ($scModel -ne $this.ActiveModel -or (![string]::IsNullOrEmpty($scPlan) -and $scPlan -ne $this.ActivePlan))) {
                    $this.ActiveModel = $scModel
                    if (![string]::IsNullOrEmpty($scPlan)) { $this.ActivePlan = $scPlan }
                    $this.UpdateModelLimits()
                }
            }
            if ($null -ne $data.live_plan_name -and ![string]::IsNullOrEmpty([string]$data.live_plan_name)) {
                $this.LivePlanName = [string]$data.live_plan_name
            }

            # 1. Sync RateLimits (Single Source of Truth)
            if ($data.rate_limits) {
                $rl = $data.rate_limits
                $this.RateLimits.CurrentRPM = [int]$rl.current_rpm
                $this.RateLimits.MaxRPM = [int]$rl.max_rpm
                $this.RateLimits.CurrentTPM = [long]$rl.current_tpm
                $this.RateLimits.MaxTPM = [long]$rl.max_tpm
                $this.RateLimits.CurrentTPS = [double]$rl.current_tps
                $this.RateLimits.MaxTPS = [double]$rl.max_tps
                $this.RateLimits.CurrentRPD = [int]$rl.current_rpd
                $this.RateLimits.MaxRPD = [int]$rl.max_rpd
                $this.RateLimits.ContextWindow = [long]$rl.context_window
                $this.RateLimits.ResetCountdown = [string]$rl.reset_countdown
            }

            # 2. Sync LastTurn
            if ($data.last_turn) {
                $lt = $data.last_turn
                $this.LastTurn.Model = if ($null -ne $lt.model) { [string]$lt.model } else { "" }
                $this.LastTurn.InvokedModelId = if ($null -ne $lt.invoked_model_id) { [string]$lt.invoked_model_id } else { "" }
                $this.LastTurn.InputTokens = [long]$lt.input_tokens
                $this.LastTurn.CacheReadTokens = [long]$lt.cache_read_tokens
                $this.LastTurn.OutputTokens = [long]$lt.output_tokens
                $this.LastTurn.TotalTokens = [long]$lt.total_tokens
                $this.LastTurn.CacheHitRate = [double]$lt.cache_hit_rate
                $this.LastTurn.CostUSD = [double]$lt.cost_usd
                $this.LastTurn.CostCNY = [double]$lt.cost_cny
                $this.LastTurn.SavingsUSD = [double]$lt.savings_usd
                $this.LastTurn.SavingsCNY = [double]$lt.savings_cny
            }

            # 3. Sync Session
            if ($data.session) {
                $s = $data.session
                $this.Session.Turns = [int]$s.turns
                $this.Session.InputTokens = [long]$s.input_tokens
                $this.Session.CacheReadTokens = [long]$s.cache_read_tokens
                $this.Session.OutputTokens = [long]$s.output_tokens
                $this.Session.TotalTokens = [long]$s.total_tokens
                $this.Session.CurrentContext = [long]$s.current_context
                $this.Session.ContextPct = [double]$s.context_pct
                $this.Session.CostUSD = [double]$s.cost_usd
                $this.Session.CostCNY = [double]$s.cost_cny
                $this.Session.SavingsUSD = [double]$s.savings_usd
                $this.Session.SavingsCNY = [double]$s.savings_cny
            }

            # 4. Sync Today
            if ($data.today) {
                $td = $data.today
                $this.Today.Turns = [int]$td.turns
                $this.Today.TotalTokens = [long]$td.total_tokens
                $this.Today.CostCNY = [double]$td.cost_cny
                $this.Today.CostUSD = [double]$td.cost_usd
                $this.Today.SavingsCNY = [double]$td.savings_cny
                $this.Today.SavingsUSD = [double]$td.savings_usd
            }

            # 5. Sync FiveHour & Weekly (5H 额度 & 总额度 for active pool)
            if ($data.five_hour) {
                $this.FiveHour.RemainingPct = [int]$data.five_hour.remaining_pct
                $this.FiveHour.ResetDisplay = [string]$data.five_hour.reset_display
                $this.FiveHour.PoolLabel = if ($null -ne $data.five_hour.pool_label) { [string]$data.five_hour.pool_label } else { "Gemini 共享池" }
                $this.FiveHour.WindowLabel = if ($null -ne $data.five_hour.window_label) { [string]$data.five_hour.window_label } else { "5h 周期池" }
                $this.FiveHour.Disabled = ($null -ne $data.five_hour.disabled -and [bool]$data.five_hour.disabled)
                $this.FiveHour.RowLabel = if ($null -ne $data.five_hour.row_label -and ![string]::IsNullOrEmpty([string]$data.five_hour.row_label)) { [string]$data.five_hour.row_label } elseif ($this.FiveHour.Disabled) { "未解锁" } else { "5H 额度" }
            }
            $wk = $data.weekly
            if ($wk) {
                $this.Weekly.RemainingPct = [int]$wk.remaining_pct
                $this.Weekly.ResetDisplay = [string]$wk.reset_display
                $this.Weekly.ShortLabel = if ($null -ne $wk.short_label -and ![string]::IsNullOrEmpty([string]$wk.short_label)) { [string]$wk.short_label } elseif ($this.Weekly.Disabled) { "未解锁" } else { "总额度" }
                $this.Weekly.PoolLabel = if ($null -ne $wk.pool_label) { [string]$wk.pool_label } else { $this.FiveHour.PoolLabel }
                $this.Weekly.Disabled = ($null -ne $wk.disabled -and [bool]$wk.disabled)
            }

            # 6. Sync ModelQuotas (Canonical Keys Matching HakimiWidget.ps1)
            if ($data.model_quotas) {
                $this.ModelQuotas.Clear()
                foreach ($mq in $data.model_quotas) {
                    $mId = [string]$mq.id
                    $mInfo = if ($this.Pricing -and $this.Pricing.models.ContainsKey($mId)) { $this.Pricing.models[$mId] } else { $null }
                    $remVal = if ($null -ne $mq.remaining_pct) { [int]$mq.remaining_pct } else { [int]$mq.five_hour_remaining_pct }
                    $resVal = if ($null -ne $mq.reset_display -and ![string]::IsNullOrEmpty([string]$mq.reset_display)) { [string]$mq.reset_display } else { [string]$mq.five_hour_reset }
                    $this.ModelQuotas.Add(@{
                        Key = $mId
                        DisplayName = [string]$mq.name
                        ShortName = if ($null -ne $mq.short_name -and ![string]::IsNullOrEmpty([string]$mq.short_name)) { [string]$mq.short_name } elseif ($mInfo) { [string]$mInfo.short_name } else { [string]$mq.name }
                        Vendor = if ($null -ne $mq.vendor -and ![string]::IsNullOrEmpty([string]$mq.vendor)) { [string]$mq.vendor } elseif ($mId -like "claude*") { "Claude" } else { "Gemini" }
                        Badge = if ($null -ne $mq.badge) { [string]$mq.badge } else { "PRO" }
                        QuotaPool = if ($null -ne $mq.quota_pool -and ![string]::IsNullOrEmpty([string]$mq.quota_pool)) { [string]$mq.quota_pool } elseif ($mInfo) { [string]$mInfo.quota_pool } else { $mId }
                        PoolLabel = if ($null -ne $mq.pool_label -and ![string]::IsNullOrEmpty([string]$mq.pool_label)) { [string]$mq.pool_label } elseif ($mInfo) { [string]$mInfo.pool_label } else { "独立池" }
                        WindowLabel = if ($null -ne $mq.window_label -and ![string]::IsNullOrEmpty([string]$mq.window_label)) { [string]$mq.window_label } else { "5h 周期池" }
                        IsWeekly = ($null -ne $mq.is_weekly -and [bool]$mq.is_weekly)
                        Disabled = ($null -ne $mq.disabled -and [bool]$mq.disabled)
                        RemainingPct = $remVal
                        ResetDisplay = $resVal
                        IsActive = [bool]$mq.is_active
                        FiveHourUsedTurns = if ($null -ne $mq.five_hour_used_turns) { [int]$mq.five_hour_used_turns } else { 0 }
                        FiveHourLimitTurns = if ($null -ne $mq.five_hour_limit_turns) { [int]$mq.five_hour_limit_turns } else { 1500 }
                        FiveHourRemainingPct = [int]$mq.five_hour_remaining_pct
                        WeeklyRemainingPct = [int]$mq.weekly_remaining_pct
                        FiveHourReset = [string]$mq.five_hour_reset
                        WeeklyReset = [string]$mq.weekly_reset
                    })
                }
            }

            $this.SidecarOnline = $true
            return $true
        } catch {
            $this.SidecarOnline = $false
            return $false
        }
    }

    [void]PollUpdates() {
        if ($this.SyncFromSidecar()) {
            return
        }

        $pbtxtModel = $this.DetectAntigravityActiveModel()
        if (![string]::IsNullOrEmpty($pbtxtModel) -and $pbtxtModel -ne $this.LastPbtxtModel) {
            $this.LastPbtxtModel = $pbtxtModel
            $this.ActiveModel = $pbtxtModel
            $this.UpdateModelLimits()
            $this.ScanAllWindows()
        }

        $this.CheckActiveConversation()
        if (!(Test-Path $this.CurrentTranscriptPath)) { return }

        $fi = [System.IO.FileInfo]::new($this.CurrentTranscriptPath)
        $fi.Refresh()
        $hasNewTurn = $false
        if ($fi.Length -gt $this.LastFileOffset) {
            try {
                $fs = [System.IO.FileStream]::new($this.CurrentTranscriptPath, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::ReadWrite)
                $fs.Seek($this.LastFileOffset, [System.IO.SeekOrigin]::Begin) | Out-Null
                $reader = [System.IO.StreamReader]::new($fs, [System.Text.Encoding]::UTF8)
                while (!$reader.EndOfStream) {
                    $line = $reader.ReadLine()
                    if ([string]::IsNullOrWhiteSpace($line)) { continue }
                    if ($line.IndexOf('"input_tokens"') -ge 0) {
                        $d = $line | ConvertFrom-Json
                        if ($null -ne $d.input_tokens) {
                            $this.ProcessStep($d, $true)
                            $hasNewTurn = $true
                        }
                    }
                }
                $this.LastFileOffset = $fs.Position
                $reader.Dispose()
                $fs.Dispose()

                if ($hasNewTurn) {
                    $this.LastQuotaSync = [datetime]::MinValue
                    $this.RecalculateSessionCost()
                    $this.ScanAllWindows()
                    if ($this.OnTurnFinished) {
                        try {
                            & $this.OnTurnFinished $this.LastTurn
                        } catch {}
                    }
                }
            } catch {}
        }

        if (!$hasNewTurn -and ([datetime]::UtcNow - $this.LastQuotaSync).TotalSeconds -ge 15) {
            $this.ScanAllWindows()
        }

        $this.UpdateRollingRateLimits()
    }

    [void]ProcessStep($d, [bool]$isLive) {
        $inp = [long]$d.input_tokens
        $cache = 0L
        if ($null -ne $d.cache_read_tokens) { $cache = [long]$d.cache_read_tokens }
        $out = 0L
        if ($null -ne $d.output_tokens) { $out = [long]$d.output_tokens }
        $tot = $inp + $cache + $out
        $rate = 0.0
        if (($inp + $cache) -gt 0) {
            $rate = [Math]::Round(($cache / [double]($inp + $cache)) * 100.0, 1)
        }

        $stepModel = $this.GetConversationModel($this.CurrentConvId)
        $stepCost = $this.CalculateCost($inp, $cache, $out, $stepModel)

        $this.LastTurn.Model = $stepModel
        $this.LastTurn.InvokedModelId = $stepModel
        $this.LastTurn.InputTokens = $inp
        $this.LastTurn.CacheReadTokens = $cache
        $this.LastTurn.OutputTokens = $out
        $this.LastTurn.TotalTokens = $tot
        $this.LastTurn.CacheHitRate = $rate
        $this.LastTurn.CostUSD = $stepCost.CostUSD
        $this.LastTurn.CostCNY = $stepCost.CostCNY
        $this.LastTurn.SavingsUSD = $stepCost.SavingsUSD
        $this.LastTurn.SavingsCNY = $stepCost.SavingsCNY

        $this.Session.Turns += 1
        $this.Session.InputTokens += $inp
        $this.Session.CacheReadTokens += $cache
        $this.Session.OutputTokens += $out
        $this.Session.TotalTokens += $tot
        $this.Session.CurrentContext = $tot
        $this.Session.RawCostUSD += [double]$stepCost.RawCostUSD
        $this.Session.RawSavingsUSD += [double]$stepCost.RawSavingsUSD

        $rateCny = [double]$this.Pricing.usd_to_cny
        $this.Session.CostUSD = [Math]::Round($this.Session.RawCostUSD, 6)
        $this.Session.CostCNY = [Math]::Round($this.Session.RawCostUSD * $rateCny, 4)
        $this.Session.SavingsUSD = [Math]::Round($this.Session.RawSavingsUSD, 6)
        $this.Session.SavingsCNY = [Math]::Round($this.Session.RawSavingsUSD * $rateCny, 4)

        if ($this.RateLimits.ContextWindow -gt 0) {
            $this.Session.ContextPct = [Math]::Round(($tot / [double]$this.RateLimits.ContextWindow) * 100.0, 1)
        }

        if ($isLive) {
            $this.RecentRequests.Add(@{
                Time = [datetime]::UtcNow
                Tokens = $tot
            })
        }
    }

    [void]RecalculateSessionCost() {
        $convModel = $this.GetConversationModel($this.CurrentConvId)
        $lt = $this.CalculateCost($this.LastTurn.InputTokens, $this.LastTurn.CacheReadTokens, $this.LastTurn.OutputTokens, $convModel)
        $this.LastTurn.Model = $convModel
        if ([string]::IsNullOrEmpty([string]$this.LastTurn.InvokedModelId)) {
            $this.LastTurn.InvokedModelId = $convModel
        }
        $this.LastTurn.CostUSD = $lt.CostUSD
        $this.LastTurn.CostCNY = $lt.CostCNY
        $this.LastTurn.SavingsUSD = $lt.SavingsUSD
        $this.LastTurn.SavingsCNY = $lt.SavingsCNY

        if ([double]$this.Session.RawCostUSD -gt 0 -or $this.Session.Turns -eq 0) {
            $rateCny = [double]$this.Pricing.usd_to_cny
            $this.Session.CostUSD = [Math]::Round([double]$this.Session.RawCostUSD, 6)
            $this.Session.CostCNY = [Math]::Round([double]$this.Session.RawCostUSD * $rateCny, 4)
            $this.Session.SavingsUSD = [Math]::Round([double]$this.Session.RawSavingsUSD, 6)
            $this.Session.SavingsCNY = [Math]::Round([double]$this.Session.RawSavingsUSD * $rateCny, 4)
        } else {
            $sc = $this.CalculateCost($this.Session.InputTokens, $this.Session.CacheReadTokens, $this.Session.OutputTokens, $convModel)
            $this.Session.CostUSD = $sc.CostUSD
            $this.Session.CostCNY = $sc.CostCNY
            $this.Session.SavingsUSD = $sc.SavingsUSD
            $this.Session.SavingsCNY = $sc.SavingsCNY
        }
    }

    [void]ScanAllWindows() {
        if (!(Test-Path $this.BrainPath)) { return }
        $pattern = Join-Path $this.BrainPath "*\.system_generated\logs\transcript.jsonl"
        $files = Get-ChildItem -Path $pattern -ErrorAction SilentlyContinue
        $nowUtc = [datetime]::UtcNow
        $todayStr = $nowUtc.ToString("yyyy-MM-dd")
        $cutoff5h = $nowUtc.AddHours(-5)
        $cutoff7d = $nowUtc.AddDays(-7)
        $cutoff1m = $nowUtc.AddSeconds(-60)

        $tTurns = 0; $tInp = 0L; $tCache = 0L; $tOut = 0L
        $tCostUsd = 0.0; $tSavingsUsd = 0.0
        $oldest5h = [datetime]::MaxValue
        $oldest7d = [datetime]::MaxValue

        $this.RecentRequests.Clear()

        $realModels = @(
            "gemini-4-neon",
            "gemini-4-carbon",
            "gemini-4-hydrogen",
            "gemini-4-argon",
            "gemini-3.8-flash",
            "claude-opus-5-5",
            "claude-sonnet-5-5"
        )
        $poolBuckets = @{}
        foreach ($mk in $realModels) {
            $pname = if ($this.Pricing -and $this.Pricing.models.ContainsKey($mk)) { [string]$this.Pricing.models[$mk].quota_pool } else { $mk }
            if ([string]::IsNullOrEmpty($pname)) { $pname = $mk }
            if (!$poolBuckets.ContainsKey($pname)) {
                $poolBuckets[$pname] = @{
                    Turns5h = 0
                    Tokens5h = 0L
                    Turns7d = 0
                    Tokens7d = 0L
                    Oldest5h = [datetime]::MaxValue
                    Oldest7d = [datetime]::MaxValue
                }
            }
        }

        $rxInp = [regex]'"input_tokens":\s*(\d+)'
        $rxCache = [regex]'"cache_read_tokens":\s*(\d+)'
        $rxOut = [regex]'"output_tokens":\s*(\d+)'
        $rxCreated = [regex]'"created_at":\s*"([^"]+)"'

        foreach ($f in $files) {
            try {
                if ($f.LastWriteTimeUtc -lt $cutoff7d) { continue }
                $cid = $f.Directory.Parent.Parent.Name
                $convModel = $this.GetConversationModel($cid)
                $pname = if ($this.Pricing -and $this.Pricing.models.ContainsKey($convModel)) { [string]$this.Pricing.models[$convModel].quota_pool } else { "gemini" }
                if (!$poolBuckets.ContainsKey($pname)) {
                    $pname = "gemini"
                }

                $fKey = $f.FullName
                $fSig = "$($f.Length)|$($f.LastWriteTimeUtc.Ticks)"
                $parsedSteps = $null
                if ($this.TranscriptFileCache.ContainsKey($fKey)) {
                    $ce = $this.TranscriptFileCache[$fKey]
                    if ($ce.Sig -eq $fSig) {
                        $parsedSteps = $ce.Steps
                    }
                }
                if ($null -eq $parsedSteps) {
                    $parsedSteps = [System.Collections.Generic.List[hashtable]]::new()
                    $fs = [System.IO.FileStream]::new($f.FullName, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::ReadWrite)
                    $sr = [System.IO.StreamReader]::new($fs, [System.Text.Encoding]::UTF8)
                    try {
                        while (!$sr.EndOfStream) {
                            $line = $sr.ReadLine()
                            if ([string]::IsNullOrWhiteSpace($line) -or $line.IndexOf('"input_tokens"') -lt 0) { continue }
                            $mInp = $rxInp.Match($line)
                            if (!$mInp.Success) { continue }
                            $sInp = [long]$mInp.Groups[1].Value
                            $mCache = $rxCache.Match($line)
                            $sCache = if ($mCache.Success) { [long]$mCache.Groups[1].Value } else { 0L }
                            $mOut = $rxOut.Match($line)
                            $sOut = if ($mOut.Success) { [long]$mOut.Groups[1].Value } else { 0L }
                            $stUtc = $nowUtc
                            $mCrt = $rxCreated.Match($line)
                            if ($mCrt.Success) {
                                [datetime]::TryParse($mCrt.Groups[1].Value, [ref]$stUtc) | Out-Null
                                $stUtc = $stUtc.ToUniversalTime()
                            }
                            $parsedSteps.Add(@{
                                StUtc = $stUtc
                                DateStr = $stUtc.ToString("yyyy-MM-dd")
                                Inp = $sInp
                                Cache = $sCache
                                Out = $sOut
                                Tot = ($sInp + $sCache + $sOut)
                            })
                        }
                    } finally {
                        $sr.Dispose()
                        $fs.Dispose()
                    }
                    $this.TranscriptFileCache[$fKey] = @{ Sig = $fSig; Steps = $parsedSteps }
                }

                foreach ($st in $parsedSteps) {
                    $stUtc = $st.StUtc
                    $sInp = $st.Inp
                    $sCache = $st.Cache
                    $sOut = $st.Out
                    $sTot = $st.Tot

                    if ($st.DateStr -eq $todayStr) {
                        $tTurns += 1
                        $tInp += $sInp
                        $tCache += $sCache
                        $tOut += $sOut
                        $scToday = $this.CalculateCost($sInp, $sCache, $sOut, $convModel)
                        $tCostUsd += [double]$scToday.RawCostUSD
                        $tSavingsUsd += [double]$scToday.RawSavingsUSD
                    }

                    if ($stUtc -ge $cutoff1m) {
                        $this.RecentRequests.Add(@{ Time = $stUtc; Tokens = $sTot })
                    }

                    if ($stUtc -ge $cutoff7d) {
                        $mb = $poolBuckets[$pname]
                        if ($stUtc -lt $mb.Oldest7d) { $mb.Oldest7d = $stUtc }
                        $mb.Turns7d += 1
                        $mb.Tokens7d += $sTot

                        if ($stUtc -ge $cutoff5h) {
                            if ($stUtc -lt $mb.Oldest5h) { $mb.Oldest5h = $stUtc }
                            $mb.Turns5h += 1
                            $mb.Tokens5h += $sTot
                        }
                    }
                }
            } catch {}
        }

        $this.Today.Turns = $tTurns
        $this.Today.InputTokens = $tInp
        $this.Today.CacheReadTokens = $tCache
        $this.Today.OutputTokens = $tOut
        $this.Today.TotalTokens = $tInp + $tCache + $tOut
        $rateToday = [double]$this.Pricing.usd_to_cny
        $this.Today.CostUSD = [Math]::Round($tCostUsd, 6)
        $this.Today.CostCNY = [Math]::Round($tCostUsd * $rateToday, 4)
        $this.Today.SavingsUSD = [Math]::Round($tSavingsUsd, 6)
        $this.Today.SavingsCNY = [Math]::Round($tSavingsUsd * $rateToday, 4)
        $this.RateLimits.CurrentRPD = $tTurns

        # Fetch official live quotas from Antigravity language_server (HTTPS + HTTP)
        $live = $this.FetchLiveAntigravityQuotas()

        $mult = 1.0
        if ($this.Pricing -and $this.Pricing.limits -and $this.Pricing.limits[$this.ActivePlan]) {
            $mult = [double]$this.Pricing.limits[$this.ActivePlan].quota_multiplier
        }

        $this.ModelQuotas.Clear()
        $activeMq = $null

        if ($this.Pricing) {
            foreach ($mk in $realModels) {
                if (!$this.Pricing.models.ContainsKey($mk)) { continue }
                $minfo = $this.Pricing.models[$mk]
                $qPool = if ($minfo.quota_pool) { [string]$minfo.quota_pool } else { $mk }
                $pLabel = if ($minfo.pool_label) { [string]$minfo.pool_label } else { "独立池" }
                $b = $poolBuckets[$qPool]
                $mLim5hTurns = [int]([Math]::Round($minfo.quota_5h_turns * $mult))
                $mLim7dTurns = [int]([Math]::Round($minfo.quota_weekly_turns * $mult))

                $localUsed5h = [int][Math]::Min(100, [Math]::Max(0, [Math]::Round($(if ($mLim5hTurns -gt 0) { ($b.Turns5h / [double]$mLim5hTurns) * 100.0 } else { 0.0 }))))
                $localUsed7d = [int][Math]::Min(100, [Math]::Max(0, [Math]::Round($(if ($mLim7dTurns -gt 0) { ($b.Turns7d / [double]$mLim7dTurns) * 100.0 } else { 0.0 }))))
                $rem5h = [Math]::Max(0, 100 - $localUsed5h)
                $rem7d = [Math]::Max(0, 100 - $localUsed7d)
                $r5Dt = if ($b.Oldest5h -ne [datetime]::MaxValue) { $b.Oldest5h.AddHours(5) } else { $nowUtc.AddHours(5) }
                $r7Dt = if ($b.Oldest7d -ne [datetime]::MaxValue) { $b.Oldest7d.AddDays(7) } else { $nowUtc.AddDays(7) }
                $res5h = "本地估算 " + $r5Dt.ToLocalTime().ToString("HH:mm")
                $res7d = "本地估算 " + $r7Dt.ToLocalTime().ToString("MM-dd HH:mm")

                $isDis = $false
                $isWeekly = ($this.QuotaViewMode -eq "weekly")
                $pct = if ($isWeekly) { $rem7d } else { $rem5h }
                $resDisp = if ($isWeekly) { $res7d } else { $res5h }
                $winLabel = if ($isWeekly) { "本地估算周额" } else { "本地估算 5h" }

                if ($null -ne $live -and $live.Models.ContainsKey($mk)) {
                    $lq = $live.Models[$mk]
                    $isDis = [bool]$lq.Disabled
                    $lqIsWk = [bool]$lq.IsWeeklyWindow
                    $lqPct = [int]$lq.RemainingPct
                    $lqRes = [string]$lq.ResetDisplay
                    if ($isDis) {
                        $rem5h = 0; $rem7d = 0; $res5h = $lqRes; $res7d = "需 Ultra 订阅"
                        $pct = 0; $resDisp = $lqRes; $winLabel = [string]$lq.WindowLabel
                    } else {
                        $has5h = [bool]$lq.HasLive5h
                        $hasWk = [bool]$lq.HasLiveWeekly
                        if ($has5h) {
                            $rem5h = [int]$lq.FiveHourRemainingPct
                            $res5h = [string]$lq.FiveHourReset
                        } elseif (!$lqIsWk) {
                            $rem5h = $lqPct; $res5h = $lqRes
                        }
                        if ($hasWk) {
                            $rem7d = [int]$lq.WeeklyRemainingPct
                            $res7d = [string]$lq.WeeklyReset
                        } elseif ($lqIsWk) {
                            $rem7d = $lqPct; $res7d = $lqRes
                        }

                        if ($this.QuotaViewMode -eq "weekly") {
                            $isWeekly = $true
                            $pct = $rem7d
                            $resDisp = $res7d
                            $winLabel = if ($hasWk -or $lqIsWk) { "总额度 (周限)" } else { "本地估算周额" }
                        } else {
                            $isWeekly = $false
                            $pct = $rem5h
                            $resDisp = $res5h
                            $winLabel = if ($has5h -or !$lqIsWk) { "5h 周期池" } else { "本地估算 5h" }
                        }
                    }
                } elseif ($isDis) {
                    $rem5h = 0; $rem7d = 0; $res5h = $resDisp; $res7d = "需 Ultra 订阅"
                }

                $mqEntry = @{
                    Key = $mk
                    DisplayName = $minfo.display_name
                    ShortName = $minfo.short_name
                    Vendor = $minfo.vendor
                    Badge = $minfo.badge
                    QuotaPool = $qPool
                    PoolLabel = $pLabel
                    WindowLabel = $winLabel
                    IsWeekly = $isWeekly
                    Disabled = $isDis
                    RemainingPct = $pct
                    ResetDisplay = $resDisp
                    IsActive = ($mk -eq $this.ActiveModel)
                    FiveHourUsedTurns = $b.Turns5h
                    FiveHourLimitTurns = $mLim5hTurns
                    FiveHourUsedPct = (100 - $rem5h)
                    FiveHourRemainingPct = $rem5h
                    FiveHourReset = $res5h
                    WeeklyUsedTurns = $b.Turns7d
                    WeeklyLimitTurns = $mLim7dTurns
                    WeeklyUsedPct = (100 - $rem7d)
                    WeeklyRemainingPct = $rem7d
                    WeeklyReset = $res7d
                }
                $this.ModelQuotas.Add($mqEntry)
                if ($mk -eq $this.ActiveModel) {
                    $activeMq = $mqEntry
                }
            }
        }

        if ($null -eq $activeMq -and $this.ModelQuotas.Count -gt 0) {
            $activeMq = $this.ModelQuotas[0]
        }

        if ($null -ne $activeMq) {
            $this.FiveHour.Turns = $activeMq.FiveHourUsedTurns
            $this.FiveHour.LimitTurns = $activeMq.FiveHourLimitTurns
            $this.FiveHour.UsedPct = (100 - $activeMq.FiveHourRemainingPct)
            $this.FiveHour.RemainingPct = $activeMq.FiveHourRemainingPct
            $this.FiveHour.ResetDisplay = $activeMq.FiveHourReset
            $this.FiveHour.PoolLabel = $activeMq.PoolLabel
            $this.FiveHour.WindowLabel = "5h 周期池"
            $this.FiveHour.Disabled = $activeMq.Disabled
            $this.FiveHour.RowLabel = if ($activeMq.Disabled) { "未解锁" } else { "5H 额度" }

            $this.Weekly.Turns = $activeMq.WeeklyUsedTurns
            $this.Weekly.LimitTurns = $activeMq.WeeklyLimitTurns
            $this.Weekly.UsedPct = (100 - $activeMq.WeeklyRemainingPct)
            $this.Weekly.RemainingPct = $activeMq.WeeklyRemainingPct
            $this.Weekly.ResetDisplay = $activeMq.WeeklyReset
            $this.Weekly.ShortLabel = if ($activeMq.Disabled) { "未解锁" } else { "总额度" }
            $this.Weekly.PoolLabel = $activeMq.PoolLabel
            $this.Weekly.Disabled = $activeMq.Disabled
        }
    }

    [void]ScanTodayTotal() {
        $this.ScanAllWindows()
    }

    [void]UpdateRollingRateLimits() {
        $now = [datetime]::UtcNow
        $cutoff = $now.AddSeconds(-60)

        for ($i = $this.RecentRequests.Count - 1; $i -ge 0; $i--) {
            if ($this.RecentRequests[$i].Time -lt $cutoff) {
                $this.RecentRequests.RemoveAt($i)
            }
        }

        $this.RateLimits.CurrentRPM = $this.RecentRequests.Count
        $tpm = 0L
        foreach ($r in $this.RecentRequests) {
            $tpm += [long]$r.Tokens
        }
        $this.RateLimits.CurrentTPM = $tpm
        $this.RateLimits.CurrentTPS = [Math]::Round([double]$tpm / 60.0, 1)

        $tomorrow = $now.Date.AddDays(1)
        $diff = $tomorrow - $now
        $this.RateLimits.ResetCountdown = [string]::Format("{0:D2}:{1:D2}:{2:D2}", [int]$diff.TotalHours, $diff.Minutes, $diff.Seconds)
    }
}
