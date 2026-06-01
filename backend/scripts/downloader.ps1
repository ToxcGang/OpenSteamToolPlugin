param(
    [Parameter(Mandatory = $true)][string]$Url,
    [Parameter(Mandatory = $true)][string]$DestPath,
    [Parameter(Mandatory = $true)][string]$ExtractDir,
    [string]$StateFile,
    [string]$UserAgent = "discord(dot)gg/luatools"
)

$ErrorActionPreference = 'Stop'

function Update-State($s) {
    if ([string]::IsNullOrWhiteSpace($StateFile)) { return }
    Set-Content -Path $StateFile -Value ("{`"status`":`"" + $s + "`"}")
}

try {
    Update-State 'downloading'
    Invoke-WebRequest -Uri $Url -OutFile $DestPath -UserAgent $UserAgent -UseBasicParsing
    
    if (-not [string]::IsNullOrWhiteSpace($ExtractDir)) {
        Update-State 'extracting'
        Expand-Archive -Force -Path $DestPath -DestinationPath $ExtractDir
        Update-State 'extracted'
    }
    else {
        Update-State 'done'
    }
}
catch {
    if (-not [string]::IsNullOrWhiteSpace($StateFile)) {
        $errMsg = $_.Exception.Message.Replace('\', '\\').Replace('"', '\"')
        Set-Content -Path $StateFile -Value ("{`"status`":`"failed`",`"error`":`"" + $errMsg + "`"}")
    }
    exit 1
}
