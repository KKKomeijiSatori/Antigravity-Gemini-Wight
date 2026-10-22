<#
.SYNOPSIS
    Antigravity Token Monitor & Live Official Quota Synchronizer
    Strictly 4 Models: Gemini 4 Argon, Gemini 3.8 Flash, Claude Opus 5.5, Claude Sonnet 5.5
    Fetches real-time official quotas directly from Antigravity language_server.exe (GetUserStatus RPC)
#>

class AntigravityMonitor {
    [string]$BrainPath
    [string]$AgyDataPath
    [string]$ConfigDir
    [hashtable]$Pricing
    [string]$ActiveModel
    [string]$ActivePlan
    [string]$LastPbtxtModel = ""
    [string]$CurrentConvId = ""
    [string]$CurrentTranscriptPath = ""
    [long]$LastFileOffset = 0
    [datetime]$LastQuotaSync = [datetime]::MinValue
    [hashtable]$CachedLiveQuotas = $null

    [hashtable]$ConvModelCache = @{}

    [hashtable]$LastTurn = @{
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
    }

    [hashtable]$Weekly = @{
        Turns = 0
        TotalTokens = 0L
        LimitTurns = 15000
        LimitTokens = 500000000L
        UsedPct = 0
        RemainingPct = 100
        ResetDisplay = "重置 --:--"
    }

    [System.Collections.Generic.List[hashtable]]$ModelQuotas = [System.Collections.Generic.List[hashtable]]::new()

    [hashtable]$RateLimits = @{
        CurrentRPM = 0
        MaxRPM = 15
        CurrentTPM = 0L
        MaxTPM = 1000000L
        CurrentRPD = 0
        MaxRPD = 1500
        ContextWindow = 1048576L
        ResetCountdown = "00:00:00"
    }

    [System.Collections.Generic.List[hashtable]]$RecentRequests = [System.Collections.Generic.List[hashtable]]::new()

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
        $this.ScanAllWindows()
        $this.CheckActiveConversation()
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
                default_model = $(if ($null -ne $json.default_model) { [string]$json.default_model } else { "gemini-4-argon" })
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
            $this.RateLimits.MaxRPD = [int]$limits.rpd
        }
    }

    [string]DetectAntigravityActiveModel() {
        $pbtxtPath = Join-Path $this.AgyDataPath "antigravity_state.pbtxt"
        if (Test-Path $pbtxtPath) {
            try {
                $content = Get-Content -LiteralPath $pbtxtPath -Raw -Encoding UTF8
                if ($content -match 'last_selected_agent_model:\s*(\S+)') {
                    $raw = $Matches[1].Trim('"'' ')
                    if ($raw -match 'M417|M418|M419|argon') {
                        return "gemini-4-argon"
                    }
                    if ($raw -match 'M318|M319|M320|flash') {
                        return "gemini-3.8-flash"
                    }
                    if ($raw -match 'M400|M401|M402|M26|opus') {
                        return "claude-opus-5-5"
                    }
                    if ($raw -match 'M403|M404|M405|sonnet') {
                        return "claude-sonnet-5-5"
                    }
                }
            } catch {}
        }
        if ([string]::IsNullOrEmpty($this.ActiveModel) -or !$this.Pricing.models.ContainsKey($this.ActiveModel)) {
            return "gemini-4-argon"
        }
        return $this.ActiveModel
    }

    [object]CallLanguageServerGetUserStatus([int]$port, [string]$csrf) {
        try {
            $url = "http://127.0.0.1:$port/exa.language_server_pb.LanguageServerService/GetUserStatus"
            $req = [System.Net.HttpWebRequest]::Create($url)
            $req.Method = "POST"
            $req.ContentType = "application/json"
            $req.Timeout = 1200
            $req.ReadWriteTimeout = 1200
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

    [hashtable]FetchLiveAntigravityQuotas() {
        $nowUtc = [datetime]::UtcNow
        if ($null -ne $this.CachedLiveQuotas -and ($nowUtc - $this.LastQuotaSync).TotalSeconds -lt 10) {
            return $this.CachedLiveQuotas
        }

        $bridgePath = Join-Path $this.ConfigDir "ls_bridge.json"
        $port = 0
        $csrf = ""

        if (Test-Path $bridgePath) {
            try {
                $b = Get-Content -LiteralPath $bridgePath -Raw -Encoding UTF8 | ConvertFrom-Json
                if ($null -ne $b.port -and $null -ne $b.csrf) {
                    $port = [int]$b.port
                    $csrf = [string]$b.csrf
                }
            } catch {}
        }

        $respObj = $null
        if ($port -gt 0 -and ![string]::IsNullOrEmpty($csrf)) {
            $respObj = $this.CallLanguageServerGetUserStatus($port, $csrf)
        }

        if ($null -eq $respObj) {
            try {
                $lsProcs = @(Get-CimInstance Win32_Process -Filter "Name='language_server.exe'" -ErrorAction SilentlyContinue)
                foreach ($p in $lsProcs) {
                    $cmd = [string]$p.CommandLine
                    if ($cmd -match '--csrf_token\s+(\S+)') {
                        $candCsrf = $Matches[1].Trim('"'' ')
                        $conns = @(Get-NetTCPConnection -State Listen -OwningProcess $p.ProcessId -ErrorAction SilentlyContinue | Sort-Object LocalPort)
                        foreach ($c in $conns) {
                            $candPort = [int]$c.LocalPort
                            $respObj = $this.CallLanguageServerGetUserStatus($candPort, $candCsrf)
                            if ($null -ne $respObj) {
                                $port = $candPort
                                $csrf = $candCsrf
                                try {
                                    if (!(Test-Path $this.ConfigDir)) { New-Item -ItemType Directory -Path $this.ConfigDir -Force | Out-Null }
                                    @{ port = $port; csrf = $csrf; pid = $p.ProcessId } | ConvertTo-Json | Set-Content -LiteralPath $bridgePath -Encoding UTF8 -Force
                                } catch {}
                                break
                            }
                        }
                    }
                    if ($null -ne $respObj) { break }
                }
            } catch {}
        }

        if ($null -eq $respObj -or $null -eq $respObj.userStatus) {
            return $this.CachedLiveQuotas
        }

        $result = @{
            PlanName = "Pro"
            Models = @{}
            WeeklyResetDisplay = ""
            FiveHourResetDisplay = ""
        }

        try {
            if ($null -ne $respObj.userStatus.planStatus -and $null -ne $respObj.userStatus.planStatus.planInfo -and $null -ne $respObj.userStatus.planStatus.planInfo.planName) {
                $result.PlanName = [string]$respObj.userStatus.planStatus.planInfo.planName
            }
            $configs = $respObj.userStatus.cascadeModelConfigData.clientModelConfigs
            foreach ($cfg in $configs) {
                $mid = [string]$cfg.modelId
                $ph = ""
                if ($null -ne $cfg.modelOrAlias -and $null -ne $cfg.modelOrAlias.model) {
                    $ph = [string]$cfg.modelOrAlias.model
                }
                $targetKey = ""
                if ($mid -match '^gemini-4-argon' -or $ph -in @('MODEL_PLACEHOLDER_M417', 'MODEL_PLACEHOLDER_M418', 'MODEL_PLACEHOLDER_M419')) {
                    $targetKey = "gemini-4-argon"
                } elseif ($mid -match '^gemini-3\.8-flash' -or $ph -in @('MODEL_PLACEHOLDER_M318', 'MODEL_PLACEHOLDER_M319', 'MODEL_PLACEHOLDER_M320')) {
                    $targetKey = "gemini-3.8-flash"
                } elseif ($mid -match '^claude-opus-5-5' -or $ph -in @('MODEL_PLACEHOLDER_M400', 'MODEL_PLACEHOLDER_M401', 'MODEL_PLACEHOLDER_M402', 'MODEL_PLACEHOLDER_M26')) {
                    $targetKey = "claude-opus-5-5"
                } elseif ($mid -match '^claude-sonnet-5-5' -or $ph -in @('MODEL_PLACEHOLDER_M403', 'MODEL_PLACEHOLDER_M404', 'MODEL_PLACEHOLDER_M405')) {
                    $targetKey = "claude-sonnet-5-5"
                }
                if ([string]::IsNullOrEmpty($targetKey)) { continue }

                $q = $cfg.quotaInfo
                $remPct = 100
                $resetUtc = $nowUtc.AddHours(5)
                $hasReset = $false
                $isWeeklyWindow = $false

                if ($null -ne $q) {
                    if ($null -ne $q.resetTime -and ![string]::IsNullOrEmpty([string]$q.resetTime)) {
                        $parsedDt = $nowUtc
                        if ([datetime]::TryParse([string]$q.resetTime, [ref]$parsedDt)) {
                            $resetUtc = $parsedDt.ToUniversalTime()
                            $hasReset = $true
                        }
                    }
                    if ($null -ne $q.remainingFraction) {
                        $remPct = [int][Math]::Round([double]$q.remainingFraction * 100.0)
                    } elseif ($hasReset) {
                        $remPct = 0
                    }
                }
                $remPct = [Math]::Min(100, [Math]::Max(0, $remPct))
                $hoursLeft = ($resetUtc - $nowUtc).TotalHours
                if ($hoursLeft -gt 24.0) {
                    $isWeeklyWindow = $true
                }
                $localReset = $resetUtc.ToLocalTime()
                $resetDisp = if ($isWeeklyWindow) { "重置 " + $localReset.ToString("MM-dd HH:mm") } else { "重置 " + $localReset.ToString("HH:mm") }

                if ($isWeeklyWindow -and [string]::IsNullOrEmpty($result.WeeklyResetDisplay)) {
                    $result.WeeklyResetDisplay = $resetDisp
                } elseif (!$isWeeklyWindow -and [string]::IsNullOrEmpty($result.FiveHourResetDisplay)) {
                    $result.FiveHourResetDisplay = $resetDisp
                }

                if (!$result.Models.ContainsKey($targetKey) -or $mid -match '-high$') {
                    $result.Models[$targetKey] = @{
                        RemainingPct = $remPct
                        UsedPct = (100 - $remPct)
                        ResetUtc = $resetUtc
                        ResetDisplay = $resetDisp
                        IsWeeklyWindow = $isWeeklyWindow
                        HoursLeft = $hoursLeft
                    }
                }
            }
        } catch {}

        $this.CachedLiveQuotas = $result
        $this.LastQuotaSync = $nowUtc
        return $result
    }

    [string]GetConversationModel([string]$convId) {
        if ([string]::IsNullOrEmpty($convId)) { return $this.ActiveModel }
        if ($this.ConvModelCache.ContainsKey($convId)) {
            return [string]$this.ConvModelCache[$convId]
        }

        $dbPath = Join-Path (Join-Path $this.AgyDataPath "conversations") "$convId.db"
        if (Test-Path $dbPath) {
            try {
                $bytes = [System.IO.File]::ReadAllBytes($dbPath)
                $chunkLen = [Math]::Min(120000, $bytes.Length)
                $latin1 = [System.Text.Encoding]::GetEncoding("ISO-8859-1").GetString($bytes, [Math]::Max(0, $bytes.Length - $chunkLen), $chunkLen)

                if ($latin1 -match 'MODEL_PLACEHOLDER_M417|MODEL_PLACEHOLDER_M418|MODEL_PLACEHOLDER_M419|gemini-4-argon|argon') {
                    $this.ConvModelCache[$convId] = "gemini-4-argon"
                    return "gemini-4-argon"
                }
                if ($latin1 -match 'MODEL_PLACEHOLDER_M400|MODEL_PLACEHOLDER_M401|MODEL_PLACEHOLDER_M402|MODEL_PLACEHOLDER_M26|claude-opus') {
                    $this.ConvModelCache[$convId] = "claude-opus-5-5"
                    return "claude-opus-5-5"
                }
                if ($latin1 -match 'MODEL_PLACEHOLDER_M403|MODEL_PLACEHOLDER_M404|MODEL_PLACEHOLDER_M405|claude-sonnet') {
                    $this.ConvModelCache[$convId] = "claude-sonnet-5-5"
                    return "claude-sonnet-5-5"
                }
                if ($latin1 -match 'MODEL_PLACEHOLDER_M318|MODEL_PLACEHOLDER_M319|MODEL_PLACEHOLDER_M320|gemini-3\.8-flash|flash') {
                    $this.ConvModelCache[$convId] = "gemini-3.8-flash"
                    return "gemini-3.8-flash"
                }
            } catch {}
        }

        $detected = $this.DetectAntigravityActiveModel()
        $this.ConvModelCache[$convId] = $detected
        return $detected
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

    [void]PollUpdates() {
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

        $this.LastTurn.InputTokens = $inp
        $this.LastTurn.CacheReadTokens = $cache
        $this.LastTurn.OutputTokens = $out
        $this.LastTurn.TotalTokens = $tot
        $this.LastTurn.CacheHitRate = $rate

        $this.Session.Turns += 1
        $this.Session.InputTokens += $inp
        $this.Session.CacheReadTokens += $cache
        $this.Session.OutputTokens += $out
        $this.Session.TotalTokens += $tot
        $this.Session.CurrentContext = $tot

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
        $this.LastTurn.CostUSD = $lt.CostUSD
        $this.LastTurn.CostCNY = $lt.CostCNY
        $this.LastTurn.SavingsUSD = $lt.SavingsUSD
        $this.LastTurn.SavingsCNY = $lt.SavingsCNY

        $sc = $this.CalculateCost($this.Session.InputTokens, $this.Session.CacheReadTokens, $this.Session.OutputTokens, $convModel)
        $this.Session.CostUSD = $sc.CostUSD
        $this.Session.CostCNY = $sc.CostCNY
        $this.Session.SavingsUSD = $sc.SavingsUSD
        $this.Session.SavingsCNY = $sc.SavingsCNY
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
        $oldest5h = [datetime]::MaxValue
        $oldest7d = [datetime]::MaxValue

        $this.RecentRequests.Clear()

        $realModels = @(
            "gemini-4-argon",
            "gemini-3.8-flash",
            "claude-opus-5-5",
            "claude-sonnet-5-5"
        )
        $modelBuckets = @{}
        foreach ($mk in $realModels) {
            $modelBuckets[$mk] = @{
                Turns5h = 0
                Tokens5h = 0L
                Turns7d = 0
                Tokens7d = 0L
            }
        }

        foreach ($f in $files) {
            try {
                if ($f.LastWriteTimeUtc -lt $cutoff7d) { continue }
                $lines = Get-Content -LiteralPath $f.FullName -Encoding UTF8 -ErrorAction SilentlyContinue
                if (!$lines) { continue }

                $cid = $f.Directory.Parent.Parent.Name
                $convModel = $this.GetConversationModel($cid)
                if (!$modelBuckets.ContainsKey($convModel)) {
                    $convModel = "gemini-3.8-flash"
                }

                foreach ($line in $lines) {
                    if ([string]::IsNullOrWhiteSpace($line) -or $line.IndexOf('"input_tokens"') -lt 0) { continue }
                    $step = $line | ConvertFrom-Json
                    if ($null -eq $step.input_tokens) { continue }

                    $stUtc = $nowUtc
                    if ($null -ne $step.created_at) {
                        [datetime]::TryParse($step.created_at, [ref]$stUtc) | Out-Null
                        $stUtc = $stUtc.ToUniversalTime()
                    }

                    $sInp = [long]$step.input_tokens
                    $sCache = 0L
                    if ($null -ne $step.cache_read_tokens) { $sCache = [long]$step.cache_read_tokens }
                    $sOut = 0L
                    if ($null -ne $step.output_tokens) { $sOut = [long]$step.output_tokens }
                    $sTot = $sInp + $sCache + $sOut

                    if ($stUtc.ToString("yyyy-MM-dd") -eq $todayStr) {
                        $tTurns += 1
                        $tInp += $sInp
                        $tCache += $sCache
                        $tOut += $sOut
                    }

                    if ($stUtc -ge $cutoff1m) {
                        $this.RecentRequests.Add(@{ Time = $stUtc; Tokens = $sTot })
                    }

                    if ($stUtc -ge $cutoff7d) {
                        if ($stUtc -lt $oldest7d) { $oldest7d = $stUtc }
                        $mb = $modelBuckets[$convModel]
                        $mb.Turns7d += 1
                        $mb.Tokens7d += $sTot

                        if ($stUtc -ge $cutoff5h) {
                            if ($stUtc -lt $oldest5h) { $oldest5h = $stUtc }
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
        $tc = $this.CalculateCost($tInp, $tCache, $tOut, $this.ActiveModel)
        $this.Today.CostUSD = $tc.CostUSD
        $this.Today.CostCNY = $tc.CostCNY
        $this.Today.SavingsUSD = $tc.SavingsUSD
        $this.Today.SavingsCNY = $tc.SavingsCNY
        $this.RateLimits.CurrentRPD = $tTurns

        # Fetch official live quotas from Antigravity language_server.exe
        $live = $this.FetchLiveAntigravityQuotas()

        $mult = 1.0
        if ($this.Pricing -and $this.Pricing.limits -and $this.Pricing.limits[$this.ActivePlan]) {
            $mult = [double]$this.Pricing.limits[$this.ActivePlan].quota_multiplier
        }

        $reset5hTime = if ($oldest5h -ne [datetime]::MaxValue) { $oldest5h.AddHours(5) } else { $nowUtc.AddHours(5) }
        $reset7dTime = if ($oldest7d -ne [datetime]::MaxValue) { $oldest7d.AddDays(7) } else { $nowUtc.AddDays(7) }
        $defaultReset5hStr = "重置 " + $reset5hTime.ToLocalTime().ToString("HH:mm")
        $defaultReset7dStr = "重置 " + $reset7dTime.ToLocalTime().ToString("MM-dd HH:mm")
        if ($null -ne $live -and ![string]::IsNullOrEmpty($live.WeeklyResetDisplay)) {
            $defaultReset7dStr = $live.WeeklyResetDisplay
        }
        if ($null -ne $live -and ![string]::IsNullOrEmpty($live.FiveHourResetDisplay)) {
            $defaultReset5hStr = $live.FiveHourResetDisplay
        }

        $this.ModelQuotas.Clear()
        $activeMq = $null

        if ($this.Pricing) {
            foreach ($mk in $realModels) {
                if (!$this.Pricing.models.ContainsKey($mk)) { continue }
                $minfo = $this.Pricing.models[$mk]
                $b = $modelBuckets[$mk]
                $mLim5hTurns = [int]([Math]::Round($minfo.quota_5h_turns * $mult))
                $mLim7dTurns = [int]([Math]::Round($minfo.quota_weekly_turns * $mult))

                $localUsed5h = [int][Math]::Min(100, [Math]::Max(0, [Math]::Round($(if ($mLim5hTurns -gt 0) { ($b.Turns5h / [double]$mLim5hTurns) * 100.0 } else { 0.0 }))))
                $localUsed7d = [int][Math]::Min(100, [Math]::Max(0, [Math]::Round($(if ($mLim7dTurns -gt 0) { ($b.Turns7d / [double]$mLim7dTurns) * 100.0 } else { 0.0 }))))
                $rem5h = [Math]::Max(0, 100 - $localUsed5h)
                $rem7d = [Math]::Max(0, 100 - $localUsed7d)
                $res5h = $defaultReset5hStr
                $res7d = $defaultReset7dStr

                if ($null -ne $live -and $live.Models.ContainsKey($mk)) {
                    $lq = $live.Models[$mk]
                    if ($lq.IsWeeklyWindow) {
                        # Official Weekly Quota (e.g. Gemini 4 Argon: 55% remaining, resets 10-28 20:26)
                        $rem7d = [int]$lq.RemainingPct
                        $res7d = [string]$lq.ResetDisplay
                        $rem5h = $rem7d
                        $res5h = "同周限额"
                    } else {
                        # Official 5-Hour Quota (e.g. Gemini 3.8 Flash: 94% resets 03:29; Claude Opus/Sonnet: 0% resets 00:37)
                        $rem5h = [int]$lq.RemainingPct
                        $res5h = [string]$lq.ResetDisplay
                    }
                }

                $mqEntry = @{
                    Key = $mk
                    DisplayName = $minfo.display_name
                    ShortName = $minfo.short_name
                    Vendor = $minfo.vendor
                    Badge = $minfo.badge
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
            $this.FiveHour.UsedPct = $activeMq.FiveHourUsedPct
            $this.FiveHour.RemainingPct = $activeMq.FiveHourRemainingPct
            $this.FiveHour.ResetDisplay = $activeMq.FiveHourReset

            $this.Weekly.Turns = $activeMq.WeeklyUsedTurns
            $this.Weekly.LimitTurns = $activeMq.WeeklyLimitTurns
            $this.Weekly.UsedPct = $activeMq.WeeklyUsedPct
            $this.Weekly.RemainingPct = $activeMq.WeeklyRemainingPct
            $this.Weekly.ResetDisplay = $activeMq.WeeklyReset
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

        $tomorrow = $now.Date.AddDays(1)
        $diff = $tomorrow - $now
        $this.RateLimits.ResetCountdown = [string]::Format("{0:D2}:{1:D2}:{2:D2}", [int]$diff.TotalHours, $diff.Minutes, $diff.Seconds)
    }
}
