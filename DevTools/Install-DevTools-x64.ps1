<#
.SYNOPSIS
    Downloads and installs portable development tools to user-scoped OneDrive folder.
.DESCRIPTION
    Automatically downloads, extracts, and configures portable versions of development tools
    (Node.js, Git, Python, VS Code, Claude Code, etc.) to OneDrive\Apps-SU\<ToolName>. 
    Updates USER PATH as needed and cleans up installation files.
.PARAMETER Tools
    Array of tool names to install. If not specified, installs all available tools.
    Valid values: 'Node', 'Git', 'Python', 'VSCode', 'ClaudeCode'
.PARAMETER SkipPathUpdate
    If specified, skips updating the USER PATH environment variable.
.PARAMETER Quiet
    If specified, suppresses informational output (errors and warnings still shown).
.EXAMPLE
    .\Install-DevTools.ps1
    Installs all available tools.
.EXAMPLE
    .\Install-DevTools.ps1 -Tools 'Node','Git','ClaudeCode'
    Installs only Node.js, Git, and Claude Code.
.NOTES
    When Git is installed, the script automatically sets CLAUDE_CODE_GIT_BASH_PATH 
    environment variable to point to Git Bash for Claude Code integration.
    
    Claude Code uses Anthropic's official installation method via:
    irm https://claude.ai/install.ps1 | iex
#>
[CmdletBinding(DefaultParameterSetName = 'Default')]
Param(
    [Parameter(Mandatory = $false)]
    [ValidateSet('Node', 'Git', 'Python', 'VSCode', 'ClaudeCode', 'All')]
    [string[]]$Tools = @('All'),

    [Parameter(Mandatory = $false)]
    [switch]$SkipPathUpdate,

    [Parameter(Mandatory = $false)]
    [switch]$Quiet
)

begin {
    Set-StrictMode -Version Latest
    $ErrorActionPreference = [System.Management.Automation.ActionPreference]::Stop
    $WarningPreference = [System.Management.Automation.ActionPreference]::SilentlyContinue
    $ProgressPreference = [System.Management.Automation.ActionPreference]::SilentlyContinue

    $script:OneDriveRoot = $null
    $script:AppsRoot = $null
    $script:TempDownloadFolder = $null
    
    $script:ToolConfigs = @{
        Node = @{
            Name = 'Node.js'                    # Display name for logging
            DownloadUrl = 'https://nodejs.org/dist/v24.12.0/node-v24.12.0-win-x64.zip'  # Direct download URL
            FolderName = 'Node'                 # Installation folder name under Apps-SU
            PathSubfolder = ''                  # Subfolder to add to PATH (empty = use FolderName root)
            AdditionalPaths = @()               # Additional subfolders to add to PATH
            FlattenArchive = $true              # If true, extract to temp and move first subfolder to target
            PostInstallScript = $null
            UseOfficialInstaller = $false
        }
        Git = @{
            Name = 'Git Portable'
            DownloadUrl = 'https://github.com/git-for-windows/git/releases/download/v2.52.0.windows.1/PortableGit-2.52.0-64-bit.7z.exe'
            FolderName = 'Git'
            PathSubfolder = 'cmd'               # Git\cmd goes to PATH
            AdditionalPaths = @('bin', 'usr\bin')  # Also add Git\bin and Git\usr\bin
            FlattenArchive = $false
            UseOfficialInstaller = $false
            PostInstallScript = {               # Optional: runs after extraction
                param($ToolPath)
                $bashPath = Join-Path $ToolPath "bin\bash.exe"
                if (Test-Path -LiteralPath $bashPath) {
                    [Environment]::SetEnvironmentVariable("CLAUDE_CODE_GIT_BASH_PATH", $bashPath, "User")
                    Write-Log "Set CLAUDE_CODE_GIT_BASH_PATH to: $bashPath"
                }
            }
        }
        ClaudeCode = @{
            Name = 'Claude Code'
            DownloadUrl = $null                 # Uses official installer script
            FolderName = 'ClaudeCode'
            PathSubfolder = ''
            AdditionalPaths = @()
            FlattenArchive = $false
            UseOfficialInstaller = $true        # Flag to use Anthropic's official installation method
        }
        Python = @{
            Name = 'Python Embeddable'
            DownloadUrl = 'https://www.python.org/ftp/python/3.13.1/python-3.13.1-embed-amd64.zip'
            FolderName = 'Python'
            PathSubfolder = ''
            AdditionalPaths = @('Scripts')
            FlattenArchive = $false
            UseOfficialInstaller = $false
            PostInstallScript = {
                param($ToolPath)
                # Enable pip in embeddable Python by uncommenting 'import site'
                $pthFile = Get-ChildItem -Path $ToolPath -Filter "*._pth" | Select-Object -First 1
                if ($pthFile) {
                    $content = Get-Content $pthFile.FullName
                    $content = $content -replace '^#import site', 'import site'
                    Set-Content -Path $pthFile.FullName -Value $content
                }
                # Create Scripts folder for pip
                foreach ($additionalPath in @('Scripts')) {
                    $scriptsPath = Join-Path $ToolPath $additionalPath
                    if (-not (Test-Path $scriptsPath)) {
                        New-Item -Path $scriptsPath -ItemType Directory -Force | Out-Null
                    }
                }
            }
        }
        VSCode = @{
            Name = 'VS Code Portable'
            DownloadUrl = 'https://code.visualstudio.com/sha/download?build=stable&os=win32-x64-archive'
            FolderName = 'VSCode'
            PathSubfolder = 'bin'
            AdditionalPaths = @()
            FlattenArchive = $true
            UseOfficialInstaller = $false
            PostInstallScript = {
                param($ToolPath)
                # Create 'data' folder to enable portable mode
                $dataFolder = Join-Path $ToolPath "data"
                if (-not (Test-Path $dataFolder)) {
                    New-Item -Path $dataFolder -ItemType Directory -Force | Out-Null
                }
            }
        }
    }

    function Write-Log {
        [CmdletBinding()]
        param(
            [Parameter(Mandatory = $true)]
            [string]$Message,
            
            [Parameter(Mandatory = $false)]
            [ValidateSet('Info', 'Warning', 'Error')]
            [string]$Level = 'Info'
        )
        
        if ($Quiet -and $Level -eq 'Info') { return }
        
        switch ($Level) {
            'Warning' { Write-Warning $Message }
            'Error' { Write-Error $Message }
            default { Write-Host $Message }
        }
    }

    function Initialize-Environment {
        [CmdletBinding()]
        param()

        # Check if system is running on x64 architecture
        if ($env:PROCESSOR_ARCHITECTURE -ne 'AMD64') {
            throw "This script requires Windows x64 architecture. Current architecture: $($env:PROCESSOR_ARCHITECTURE)"
        }

        $oneDrive = $env:OneDriveCommercial
        if (-not $oneDrive) { $oneDrive = $env:OneDrive }
        if (-not $oneDrive) { $oneDrive = [Environment]::GetEnvironmentVariable("OneDriveCommercial", "User") }
        if (-not $oneDrive) { $oneDrive = [Environment]::GetEnvironmentVariable("OneDrive", "User") }

        if (-not $oneDrive) {
            throw "Unable to locate OneDrive folder for the current user."
        }

        $script:OneDriveRoot = $oneDrive
        $script:AppsRoot = Join-Path $oneDrive "Apps-SU"

        if (-not (Test-Path -LiteralPath $script:AppsRoot)) {
            New-Item -Path $script:AppsRoot -ItemType Directory -Force | Out-Null
        }

        $script:TempDownloadFolder = Join-Path $env:TEMP "DevToolsInstaller_$(Get-Date -Format 'yyyyMMdd_HHmmss')"
        New-Item -Path $script:TempDownloadFolder -ItemType Directory -Force | Out-Null

        Write-Log "OneDrive: $script:OneDriveRoot"
        Write-Log "Apps Root: $script:AppsRoot"
        Write-Log "Temp: $script:TempDownloadFolder"
    }

    function Get-FileFromUrl {
        [CmdletBinding()]
        param(
            [Parameter(Mandatory = $true)]
            [string]$Url,

            [Parameter(Mandatory = $true)]
            [string]$OutputPath
        )

        Write-Log "Downloading: $Url"
        
        $webClient = New-Object System.Net.WebClient
        
        if (-not $Quiet) {
            Register-ObjectEvent -InputObject $webClient -EventName DownloadProgressChanged -SourceIdentifier WebClient.DownloadProgressChanged -Action {
                Write-Progress -Activity "Downloading" -Status "$($EventArgs.ProgressPercentage)% Complete" -PercentComplete $EventArgs.ProgressPercentage
            } | Out-Null
        }

        try {
            $webClient.DownloadFile($Url, $OutputPath)
            if (-not (Test-Path -LiteralPath $OutputPath)) {
                throw "Download completed but file not found"
            }
        }
        finally {
            if (-not $Quiet) {
                Unregister-Event -SourceIdentifier WebClient.DownloadProgressChanged -ErrorAction SilentlyContinue
                Write-Progress -Activity "Downloading" -Completed
            }
            $webClient.Dispose()
        }
    }

    function Expand-ArchiveFile {
        [CmdletBinding()]
        param(
            [Parameter(Mandatory = $true)]
            [string]$ArchivePath,

            [Parameter(Mandatory = $true)]
            [string]$DestinationPath
        )

        Write-Log "Extracting: $ArchivePath"

        if (-not (Test-Path -LiteralPath $DestinationPath)) {
            New-Item -Path $DestinationPath -ItemType Directory -Force | Out-Null
        }

        $extension = [System.IO.Path]::GetExtension($ArchivePath).ToLower()

        switch ($extension) {
            '.zip' {
                Expand-Archive -Path $ArchivePath -DestinationPath $DestinationPath -Force
            }
            '.exe' {
                $process = Start-Process -FilePath $ArchivePath -ArgumentList "-o`"$DestinationPath`" -y" -Wait -PassThru -NoNewWindow
                if ($process.ExitCode -ne 0) {
                    throw "Extraction failed with exit code: $($process.ExitCode)"
                }
            }
            default {
                throw "Unsupported archive format: $extension"
            }
        }
    }

    function Update-UserPath {
        [CmdletBinding()]
        param(
            [Parameter(Mandatory = $true)]
            [string[]]$Paths
        )

        if ($SkipPathUpdate) {
            Write-Log "Skipping PATH update"
            return
        }

        $currentPath = [Environment]::GetEnvironmentVariable("Path", "User")
        if (-not $currentPath) { $currentPath = "" }

        $modified = $false
        foreach ($path in $Paths) {
            if (-not (Test-Path -LiteralPath $path)) {
                Write-Log "Path does not exist, skipping: $path" -Level Warning
                continue
            }

            if ($currentPath -notlike "*$path*") {
                $currentPath = "$currentPath;$path"
                $modified = $true
                Write-Log "Added to PATH: $path"
            }
        }

        if ($modified) {
            [Environment]::SetEnvironmentVariable("Path", $currentPath, "User")
            $env:Path = [Environment]::GetEnvironmentVariable("Path", "User") + ";" + [Environment]::GetEnvironmentVariable("Path", "Machine")
        }
    }

    function Install-ClaudeCodeOfficial {
        [CmdletBinding()]
        param()

        Write-Log "Installing Claude Code using official Anthropic installer..."
        Write-Log "Running: irm https://claude.ai/install.ps1 | iex"
        
        try {
            # Execute Anthropic's official installation script
            Invoke-Expression (Invoke-RestMethod -Uri 'https://claude.ai/install.ps1')
            
            Write-Log "Claude Code installation completed via official installer"
            
            # Add Claude Code bin directory to PATH
            # The installer places Claude Code in %USERPROFILE%\.local\bin
            $claudeCodeBinPath = Join-Path $env:USERPROFILE ".local\bin"
            
            if (Test-Path -LiteralPath $claudeCodeBinPath) {
                Write-Log "Found Claude Code installation at: $claudeCodeBinPath"
                
                if (-not $SkipPathUpdate) {
                    $currentPath = [Environment]::GetEnvironmentVariable("Path", "User")
                    if (-not $currentPath) { $currentPath = "" }
                    
                    if ($currentPath -notlike "*$claudeCodeBinPath*") {
                        $newPath = "$currentPath;$claudeCodeBinPath"
                        [Environment]::SetEnvironmentVariable("Path", $newPath, "User")
                        Write-Log "Added Claude Code to PATH: $claudeCodeBinPath"
                    }
                    else {
                        Write-Log "Claude Code bin directory already in PATH"
                    }
                }
                
                # Refresh the current session's PATH
                $env:Path = [Environment]::GetEnvironmentVariable("Path", "User") + ";" + [Environment]::GetEnvironmentVariable("Path", "Machine")
            }
            else {
                Write-Log "Warning: Claude Code bin directory not found at expected location: $claudeCodeBinPath" -Level Warning
                Write-Log "Claude Code may have been installed to a different location" -Level Warning
            }
            
        }
        catch {
            Write-Log "Official Claude Code installation failed: $_" -Level Error
            throw
        }
    }

    function Install-Tool {
        [CmdletBinding()]
        param(
            [Parameter(Mandatory = $true)]
            [string]$ToolName
        )

        $config = $script:ToolConfigs[$ToolName]
        if (-not $config) {
            throw "Tool configuration not found: $ToolName"
        }

        # Special handling for Claude Code with official installer
        if ($config.UseOfficialInstaller -and $ToolName -eq 'ClaudeCode') {
            Install-ClaudeCodeOfficial
            return
        }

        $toolPath = Join-Path $script:AppsRoot $config.FolderName
        
        Write-Log "Installing $($config.Name)"

        # Extract filename from URL
        $uri = [System.Uri]$config.DownloadUrl
        $fileName = [System.IO.Path]::GetFileName($uri.LocalPath)
        if ([string]::IsNullOrWhiteSpace($fileName)) {
            $fileName = "$($config.FolderName)-download.zip"
        }

        # Download
        $downloadPath = Join-Path $script:TempDownloadFolder $fileName
        Get-FileFromUrl -Url $config.DownloadUrl -OutputPath $downloadPath

        # Extract
        if ($config.FlattenArchive) {
            $tempExtractPath = Join-Path $script:TempDownloadFolder "$($config.FolderName)_extract"
            Expand-ArchiveFile -ArchivePath $downloadPath -DestinationPath $tempExtractPath
            
            $extractedFolder = Get-ChildItem -Path $tempExtractPath -Directory | Select-Object -First 1
            if (-not $extractedFolder) {
                throw "Extraction did not produce expected folder structure"
            }

            if (Test-Path -LiteralPath $toolPath) {
                Remove-Item -Path $toolPath -Recurse -Force
            }
            Move-Item -Path $extractedFolder.FullName -Destination $toolPath -Force
        }
        else {
            if (Test-Path -LiteralPath $toolPath) {
                Remove-Item -Path $toolPath -Recurse -Force
            }
            Expand-ArchiveFile -ArchivePath $downloadPath -DestinationPath $toolPath
        }

        # Post-install configuration
        if ($config.PostInstallScript) {
            & $config.PostInstallScript $toolPath
        }

        # Update PATH
        $pathsToAdd = @()
        if ($config.PathSubfolder) {
            $pathsToAdd += Join-Path $toolPath $config.PathSubfolder
        }
        else {
            $pathsToAdd += $toolPath
        }
        
        if ($config.AdditionalPaths) {
            foreach ($additionalPath in $config.AdditionalPaths) {
                $pathsToAdd += Join-Path $toolPath $additionalPath
            }
        }
        
        Update-UserPath -Paths $pathsToAdd

        Write-Log "Installed to: $toolPath"
    }

    function Remove-DownloadedFiles {
        [CmdletBinding()]
        param()

        if ($script:TempDownloadFolder -and (Test-Path -LiteralPath $script:TempDownloadFolder)) {
            Remove-Item -Path $script:TempDownloadFolder -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
}

process {
    try {
        Initialize-Environment

        $toolsToInstall = if ($Tools -contains 'All') {
            $script:ToolConfigs.Keys
        }
        else {
            $Tools
        }

        Write-Log "Installing tools: $($toolsToInstall -join ', ')"

        foreach ($tool in $toolsToInstall) {
            try {
                Install-Tool -ToolName $tool
            }
            catch {
                Write-Log "Failed to install $tool : $_" -Level Error
                throw
            }
        }

        Write-Log "Installation complete"
        Write-Log "Restart your terminal to use the new tools"
    }
    catch {
        Write-Log "Installation failed: $_" -Level Error
        throw
    }
    finally {
        Remove-DownloadedFiles
    }
}

end {
}
