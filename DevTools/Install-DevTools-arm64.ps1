<#
.SYNOPSIS
    Downloads and installs portable development tools to user-scoped OneDrive or Local folder.
.DESCRIPTION
    Automatically downloads, extracts, and configures portable versions of development tools
    (Node.js, Git, Python, VS Code, Claude Code) to either OneDrive\Apps-SU or Local\Apps-SU. 
    Updates USER PATH as needed and cleans up installation files.
    
    Before installing, checks if tools are already installed in either location.
.PARAMETER Tools
    Array of tool names to install. If not specified, installs all available tools.
    A Prerequisite to ClaudeCode is Git. If only ClaudeCode is specified, Git will be added to the list to install as well.
    Valid values: 'Node', 'Git', 'Python', 'VSCode', 'ClaudeCode', 'All'
.PARAMETER Location
    Where to install tools. Options: 'OneDrive' (default) or 'Local'
    Note: Claude Code is always installed locally regardless of this setting.
.PARAMETER SkipPathUpdate
    If specified, skips updating the USER PATH environment variable.
.PARAMETER Quiet
    If specified, suppresses informational output (errors and warnings still shown).
.EXAMPLE
    .\Install-DevTools.ps1
    Installs all available tools to OneDrive.
.EXAMPLE
    .\Install-DevTools.ps1 -Location Local
    Installs all tools locally.
.EXAMPLE
    .\Install-DevTools.ps1 -Tools 'Node','Git','ClaudeCode' -Location OneDrive
    Installs Node and Git to OneDrive, Claude Code locally.
.NOTES
    - Claude Code MUST be installed after Git
    - Git installation sets CLAUDE_CODE_GIT_BASH_PATH environment variable
    - Claude Code installation requires a new PowerShell session or PATH refresh
#>
[CmdletBinding(DefaultParameterSetName = 'Default')]
Param(
    [Parameter(Mandatory = $false)]
    [ValidateSet('Node', 'Git', 'Python', 'VSCode', 'ClaudeCode', 'All')]
    [string[]]$Tools = @('All'),

    [Parameter(Mandatory = $false)]
    [ValidateSet('OneDrive', 'Local')]
    [string]$Location = 'OneDrive',

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
    $script:OneDriveAppsRoot = $null
    $script:LocalRoot = $null
    $script:LocalAppsRoot = $null
    $script:AppsRoot = $null  # Will be set based on Location parameter
    $script:TempDownloadFolder = $null
    
    $script:ToolConfigs = @{
        Node = @{
            Name = 'Node.js'
            DownloadUrl = 'https://nodejs.org/dist/v24.12.0/node-v24.12.0-win-arm64.zip'
            FolderName = 'Node'
            PathSubfolder = ''
            AdditionalPaths = @()
            FlattenArchive = $true
            PostInstallScript = $null
            UseOfficialInstaller = $false
            ExecutablesToCheck = @("node.exe")
        }
        Git = @{
            Name = 'Git Portable'
            DownloadUrl = 'https://github.com/git-for-windows/git/releases/download/v2.52.0.windows.1/PortableGit-2.52.0-arm64.7z.exe'
            FolderName = 'PortableGit'
            PathSubfolder = 'cmd'
            AdditionalPaths = @('bin', 'usr\bin')
            FlattenArchive = $false
            UseOfficialInstaller = $false
            ExecutablesToCheck = @("cmd\git.exe", "bin\bash.exe")
            PostInstallScript = {
                param($ToolPath)
                # Set CLAUDE_CODE_GIT_BASH_PATH for Claude Code
                $bashPath = Join-Path $ToolPath "bin\bash.exe"
                if (Test-Path -LiteralPath $bashPath) {
                    [Environment]::SetEnvironmentVariable("CLAUDE_CODE_GIT_BASH_PATH", $bashPath, "User")
                    $env:CLAUDE_CODE_GIT_BASH_PATH = [Environment]::GetEnvironmentVariable("CLAUDE_CODE_GIT_BASH_PATH", "User")
                    Write-Log "Set CLAUDE_CODE_GIT_BASH_PATH to: $bashPath"
                } else {
                    Write-Log "Warning: bash.exe not found at expected location: $bashPath" -Level Warning
                }
            }
        }
        ClaudeCode = @{
            Name = 'Claude Code'
            DownloadUrl = $null
            FolderName = 'ClaudeCode'
            PathSubfolder = ''
            AdditionalPaths = @()
            FlattenArchive = $false
            UseOfficialInstaller = $true
            ExecutablesToCheck = @("claude.exe")
            RequiresGit = $true  # Flag that Git must be installed first
        }
        Python = @{
            Name = 'Python Embeddable'
            DownloadUrl = 'https://www.python.org/ftp/python/3.14.2/python-3.14.2-embed-arm64.zip'
            FolderName = 'Python'
            PathSubfolder = ''
            AdditionalPaths = @('Scripts')
            FlattenArchive = $false
            UseOfficialInstaller = $false
            ExecutablesToCheck = @("python.exe", "pythonw.exe")
            PostInstallScript = {
                param($ToolPath)
                # Enable pip in embeddable Python
                $pthFile = Get-ChildItem -Path $ToolPath -Filter "*._pth" | Select-Object -First 1
                if ($pthFile) {
                    $content = Get-Content $pthFile.FullName
                    $content = $content -replace '^#import site', 'import site'
                    Set-Content -Path $pthFile.FullName -Value $content
                }
                # Create Scripts folder
                $scriptsPath = Join-Path $ToolPath 'Scripts'
                if (-not (Test-Path $scriptsPath)) {
                    New-Item -Path $scriptsPath -ItemType Directory -Force | Out-Null
                }
            }
        }
        VSCode = @{
            Name = 'VS Code Portable'
            DownloadUrl = 'https://code.visualstudio.com/sha/download?build=stable&os=win32-arm64-archive'            
            FolderName = 'VSCode'
            PathSubfolder = 'bin'
            AdditionalPaths = @()
            FlattenArchive = $true
            UseOfficialInstaller = $false
            ExecutablesToCheck = @("bin\code.cmd")
            PostInstallScript = {
                param($ToolPath)
                # Create 'data' folder for portable mode
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
            [ValidateSet('Info', 'Warning', 'Error', 'Success')]
            [string]$Level = 'Info'
        )
        
        if ($Quiet -and $Level -eq 'Info') { return }
        
        switch ($Level) {
            'Warning' { Write-Warning $Message }
            'Error' { Write-Error $Message }
            'Success' { Write-Host $Message -BackgroundColor Yellow -ForegroundColor Black }
            default { Write-Host $Message }
        }
    }

    function Initialize-Environment {
        [CmdletBinding()]
        param()

        # Check if system is running on ARM64 architecture
        if ($env:PROCESSOR_ARCHITECTURE -ne 'ARM64') {
            throw "This script requires Windows ARM64 architecture. Current architecture: $($env:PROCESSOR_ARCHITECTURE)"
        }

        # Set up OneDrive paths
        $oneDrive = $env:OneDriveCommercial
        if (-not $oneDrive) { $oneDrive = $env:OneDrive }
        if (-not $oneDrive) { $oneDrive = [Environment]::GetEnvironmentVariable("OneDriveCommercial", "User") }
        if (-not $oneDrive) { $oneDrive = [Environment]::GetEnvironmentVariable("OneDrive", "User") }

        if ($oneDrive) {
            $script:OneDriveRoot = $oneDrive
            $script:OneDriveAppsRoot = Join-Path $oneDrive "Apps-SU"
            Write-Log "OneDrive Root: $script:OneDriveRoot"
            Write-Log "OneDrive Apps Root: $script:OneDriveAppsRoot"
        } else {
            Write-Log "OneDrive not found - Local installation only" -Level Warning
        }

        # Set up Local paths
        $localPath = $env:USERPROFILE
        if (-not $localPath) { $localPath = $HOME }
        
        if (-not $localPath) {
            throw "Unable to locate UserProfile folder"
        }

        $script:LocalRoot = $localPath
        $script:LocalAppsRoot = Join-Path $localPath "Apps-SU"
        Write-Log "Local Root: $script:LocalRoot"
        Write-Log "Local Apps Root: $script:LocalAppsRoot"

        # Set AppsRoot based on Location parameter
        if ($Location -eq 'OneDrive' -and $script:OneDriveAppsRoot) {
            $script:AppsRoot = $script:OneDriveAppsRoot
            Write-Log "Installation target: OneDrive ($script:AppsRoot)"
        } else {
            $script:AppsRoot = $script:LocalAppsRoot
            Write-Log "Installation target: Local ($script:AppsRoot)"
        }

        # Create Apps-SU directories if they don't exist
        if ($script:OneDriveAppsRoot -and -not (Test-Path -LiteralPath $script:OneDriveAppsRoot)) {
            New-Item -Path $script:OneDriveAppsRoot -ItemType Directory -Force | Out-Null
        }
        if (-not (Test-Path -LiteralPath $script:LocalAppsRoot)) {
            New-Item -Path $script:LocalAppsRoot -ItemType Directory -Force | Out-Null
        }

        # Create temp folder
        $script:TempDownloadFolder = Join-Path $env:TEMP "DevToolsInstaller_$(Get-Date -Format 'yyyyMMdd_HHmmss')"
        New-Item -Path $script:TempDownloadFolder -ItemType Directory -Force | Out-Null
        Write-Log "Temp folder: $script:TempDownloadFolder"
    }

    function Test-ToolInstalled {
        [CmdletBinding()]
        [OutputType([PSCustomObject])]
        param(
            [Parameter(Mandatory = $true)]
            [ValidateSet("Node", "Git", "ClaudeCode", "Python", "VSCode")]
            [string]$ToolName
        )

        $config = $script:ToolConfigs[$ToolName]
        
        function Test-LocationStatus {
            param(
                [string]$BasePath,
                [string[]]$ExecutablesToCheck,
                [bool]$IsClaudeCode = $false
            )

            $locationStatus = [PSCustomObject]@{
                BasePath = $BasePath
                FolderExists = $false
                ExecutablesFound = $false
                ExecutableDetails = @()
                InEnvironmentPath = $false
                MissingExecutables = @()
            }

            if ($IsClaudeCode) {
                $locationStatus | Add-Member -NotePropertyName 'GitBashPathSet' -NotePropertyValue $false
                $locationStatus | Add-Member -NotePropertyName 'GitBashPathValid' -NotePropertyValue $false
                $locationStatus | Add-Member -NotePropertyName 'GitBashPath' -NotePropertyValue ""
            }

            $locationStatus.FolderExists = Test-Path -LiteralPath $BasePath

            if (-not $locationStatus.FolderExists) {
                return $locationStatus
            }

            # Check executables
            $allExist = $true
            $missingExes = @()
            $exeDetails = @()

            foreach ($executable in $ExecutablesToCheck) {
                $exePath = Join-Path $BasePath $executable
                $exists = Test-Path -LiteralPath $exePath

                $exeDetails += [PSCustomObject]@{
                    Name = $executable
                    FullPath = $exePath
                    Found = $exists
                }

                if (-not $exists) {
                    $allExist = $false
                    $missingExes += $executable
                }
            }

            $locationStatus.ExecutablesFound = $allExist
            $locationStatus.ExecutableDetails = $exeDetails
            $locationStatus.MissingExecutables = $missingExes

            # Check PATH - look for any of the required paths
            $pathDirs = $env:Path -split ';' | ForEach-Object { $_.TrimEnd('\') }
            
            # For tools with PathSubfolder, check if that's in PATH
            if ($config.PathSubfolder) {
                $expectedPath = Join-Path $BasePath $config.PathSubfolder
                $locationStatus.InEnvironmentPath = $pathDirs -contains $expectedPath.TrimEnd('\')
            } else {
                $locationStatus.InEnvironmentPath = $pathDirs -contains $BasePath.TrimEnd('\')
            }

            # Special check for ClaudeCode
            if ($IsClaudeCode) {
                $gitBashPath = [Environment]::GetEnvironmentVariable("CLAUDE_CODE_GIT_BASH_PATH", "User")
                if (-not $gitBashPath) { $gitBashPath = $env:CLAUDE_CODE_GIT_BASH_PATH }

                $locationStatus.GitBashPathSet = -not [string]::IsNullOrEmpty($gitBashPath)
                $locationStatus.GitBashPath = $gitBashPath

                if ($locationStatus.GitBashPathSet) {
                    $locationStatus.GitBashPathValid = Test-Path -LiteralPath $gitBashPath
                }
            }

            return $locationStatus
        }

        # Determine paths
        $oneDrivePath = ""
        $localPath = ""
        $isClaudeCode = $false

        if ($ToolName -eq 'ClaudeCode') {
            # Claude Code is always in user profile
            $userProfilePath = Join-Path $env:USERPROFILE ".local\bin"
            $oneDrivePath = ""
            $localPath = $userProfilePath
            $isClaudeCode = $true
        } else {
            if ($script:OneDriveAppsRoot) { 
                $oneDrivePath = Join-Path $script:OneDriveAppsRoot $config.FolderName 
            }
            if ($script:LocalAppsRoot) { 
                $localPath = Join-Path $script:LocalAppsRoot $config.FolderName 
            }
        }

        # Check both locations
        $oneDriveStatus = if ($oneDrivePath) {
            Test-LocationStatus -BasePath $oneDrivePath -ExecutablesToCheck $config.ExecutablesToCheck -IsClaudeCode $isClaudeCode
        } else {
            [PSCustomObject]@{
                BasePath = "N/A"
                FolderExists = $false
                ExecutablesFound = $false
                ExecutableDetails = @()
                InEnvironmentPath = $false
                MissingExecutables = $config.ExecutablesToCheck
            }
        }

        $localStatus = if ($localPath) {
            Test-LocationStatus -BasePath $localPath -ExecutablesToCheck $config.ExecutablesToCheck -IsClaudeCode $isClaudeCode
        } else {
            [PSCustomObject]@{
                BasePath = "N/A"
                FolderExists = $false
                ExecutablesFound = $false
                ExecutableDetails = @()
                InEnvironmentPath = $false
                MissingExecutables = $config.ExecutablesToCheck
            }
        }

        return [PSCustomObject]@{
            ProgramName = $ToolName
            OneDrive = $oneDriveStatus
            Local = $localStatus
            IsInstalledAnywhere = ($oneDriveStatus.ExecutablesFound -or $localStatus.ExecutablesFound)
            IsInstalledBothLocations = ($oneDriveStatus.ExecutablesFound -and $localStatus.ExecutablesFound)
        }
    }

    function Test-VSCodeSystemInstalled {
        [CmdletBinding()]
        [OutputType([PSCustomObject])]
        param()

        $result = [PSCustomObject]@{
            IsInstalled = $false
            InstallPath = $null
            InEnvironmentPath = $false
        }

        # Common VS Code installation patterns in PATH
        $vsCodePathPatterns = @(
            '*Microsoft VS Code*',
            '*VSCode*'
        )

        $pathDirs = $env:Path -split ';' | Where-Object { $_ }

        foreach ($dir in $pathDirs) {
            foreach ($pattern in $vsCodePathPatterns) {
                if ($dir -like $pattern) {
                    # Verify code.cmd exists
                    $codeCmdPath = Join-Path $dir "code.cmd"
                    if (Test-Path -LiteralPath $codeCmdPath) {
                        $result.IsInstalled = $true
                        $result.InstallPath = $dir
                        $result.InEnvironmentPath = $true
                        return $result
                    }
                }
            }
        }

        return $result
    }

    function Show-InstallationStatus {
        [CmdletBinding()]
        param(
            [Parameter(Mandatory = $true)]
            [PSCustomObject]$Status
        )

        $config = $script:ToolConfigs[$Status.ProgramName]
        
        if ($Status.OneDrive.ExecutablesFound -and $Status.ProgramName -ne 'ClaudeCode') {
            Write-Log ">>> $($config.Name) is already installed in OneDrive <<<" -Level Success
            Write-Log "    Location: $($Status.OneDrive.BasePath)"
            Write-Log "    In PATH: $($Status.OneDrive.InEnvironmentPath)"
        }
        
        if ($Status.Local.ExecutablesFound) {
            Write-Log ">>> $($config.Name) is already installed Locally <<<" -Level Success
            Write-Log "    Location: $($Status.Local.BasePath)"
            Write-Log "    In PATH: $($Status.Local.InEnvironmentPath)"
            if ($Status.ProgramName -eq 'ClaudeCode') {
                Write-Log "    Git Bash Path Set: $($Status.Local.GitBashPathSet)"
                Write-Log "    Git Bash Path Valid: $($Status.Local.GitBashPathValid)"
            }
        }
        
        if ($Status.IsInstalledBothLocations) {
            Write-Log "WARNING: $($config.Name) is installed in BOTH locations - may cause conflicts!" -Level Warning
        }
    }

    function Get-EnvironmentPath {
        [CmdletBinding()]
        param()
        
        $env:Path = [Environment]::GetEnvironmentVariable("Path", "User") + ";" + 
                    [Environment]::GetEnvironmentVariable("Path", "Machine")
        $env:CLAUDE_CODE_GIT_BASH_PATH = [Environment]::GetEnvironmentVariable("CLAUDE_CODE_GIT_BASH_PATH", "User")
        Write-Log "Environment PATH refreshed"
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
            Write-Log "Skipping PATH update (SkipPathUpdate flag set)"
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

            $normalizedPath = $path.TrimEnd('\')
            $pathDirs = $currentPath -split ';' | ForEach-Object { $_.TrimEnd('\') }
            
            if ($pathDirs -notcontains $normalizedPath) {
                if ($currentPath) {
                    $currentPath = "$currentPath;$path"
                } else {
                    $currentPath = $path
                }
                $modified = $true
                Write-Log "Added to PATH: $path"
            } else {
                Write-Log "Already in PATH: $path"
            }
        }

        if ($modified) {
            [Environment]::SetEnvironmentVariable("Path", $currentPath, "User")
            Get-EnvironmentPath
            Write-Log "PATH updated successfully"
        }
    }

    function Install-ClaudeCodeOfficial {
        [CmdletBinding()]
        param()

        Write-Log "Installing Claude Code using official Anthropic installer..."
        
        # Verify Git is installed and CLAUDE_CODE_GIT_BASH_PATH is set
        $gitBashPath = [Environment]::GetEnvironmentVariable("CLAUDE_CODE_GIT_BASH_PATH", "User")
        if (-not $gitBashPath) {
            throw "CLAUDE_CODE_GIT_BASH_PATH not set. Git must be installed first."
        }
        
        if (-not (Test-Path -LiteralPath $gitBashPath)) {
            throw "CLAUDE_CODE_GIT_BASH_PATH points to invalid location: $gitBashPath"
        }

        Write-Log "Git Bash found at: $gitBashPath"
        
        # Refresh session PATH to ensure Git and other tools are available
        Get-EnvironmentPath
        
        Write-Log "Installing Claude Code..."
        try {
            # Execute Anthropic's official installation script in current session
            $null = Invoke-Expression (Invoke-RestMethod -Uri 'https://claude.ai/install.ps1')
            Write-Log "Claude Code installation completed"
        }
        catch {
            Write-Error "Claude Code installation failed: $_"
            throw
        }
        
        # Verify installation
        $claudeCodePath = Join-Path $env:USERPROFILE ".local\bin"
        $claudeExe = Join-Path $claudeCodePath "claude.exe"
        
        if (Test-Path -LiteralPath $claudeExe) {
            Write-Log "Claude Code executable found at: $claudeExe"
            
            # Ensure it's in PATH
            if (-not $SkipPathUpdate) {
                Update-UserPath -Paths @($claudeCodePath)
            }
        } else {
            throw "Claude Code installation completed but executable not found at: $claudeExe"
        }
    }

    function Install-Tool {
        [CmdletBinding()]
        param(
            [Parameter(Mandatory = $true)]
            [string]$ToolName
        )

        Write-Host $ToolName
        $config = $script:ToolConfigs[$ToolName]
        if (-not $config) {
            throw "Tool configuration not found: $ToolName"
        }

        # Special check for VS Code - see if system-installed version exists
        if ($ToolName -eq 'VSCode') {
            $systemVSCode = Test-VSCodeSystemInstalled
            if ($systemVSCode.IsInstalled) {
                Write-Log ">>> VS Code is already installed on the system <<<" -Level Success
                Write-Log "    Location: $($systemVSCode.InstallPath)"
                Write-Log "    Skipping portable installation"
                return
            }
        }

        # Check if already installed
        $status = Test-ToolInstalled -ToolName $ToolName
        
        if ($status.IsInstalledAnywhere) {
            Show-InstallationStatus -Status $status
            
            # Still update PATH if needed
            $needsPathUpdate = $false
            if ($Location -eq 'OneDrive' -and $status.OneDrive.ExecutablesFound -and -not $status.OneDrive.InEnvironmentPath) {
                $needsPathUpdate = $true
                $toolPath = $status.OneDrive.BasePath
            } elseif ($Location -eq 'Local' -and $status.Local.ExecutablesFound -and -not $status.Local.InEnvironmentPath) {
                $needsPathUpdate = $true
                $toolPath = $status.Local.BasePath
            } elseif ($ToolName -eq 'ClaudeCode' -and $status.Local.ExecutablesFound -and -not $status.Local.InEnvironmentPath) {
                $needsPathUpdate = $true
                $toolPath = $status.Local.BasePath
            }
            
            if ($needsPathUpdate) {
                Write-Log "Updating PATH for already installed $($config.Name)..."
                $pathsToAdd = @()
                if ($config.PathSubfolder) {
                    $pathsToAdd += Join-Path $toolPath $config.PathSubfolder
                } else {
                    $pathsToAdd += $toolPath
                }
                
                if ($config.AdditionalPaths) {
                    foreach ($additionalPath in $config.AdditionalPaths) {
                        $pathsToAdd += Join-Path $toolPath $additionalPath
                    }
                }
                
                Update-UserPath -Paths $pathsToAdd
            }
            
            return  # Skip installation
        }

        # Not installed - proceed with installation
        Write-Log "`nInstalling $($config.Name)..."

        # Determine installation path
        if ($ToolName -eq 'ClaudeCode') {
            # Claude Code uses official installer
            Install-ClaudeCodeOfficial
            return
        } else {
            $toolPath = Join-Path $script:AppsRoot $config.FolderName
        }

        # Download
        $uri = [System.Uri]$config.DownloadUrl
        $fileName = [System.IO.Path]::GetFileName($uri.LocalPath)
        if ([string]::IsNullOrWhiteSpace($fileName) -or [string]::IsNullOrWhiteSpace([System.IO.Path]::GetExtension($fileName))) {
            $fileName = "$($config.FolderName)-download.zip"
        }

        $downloadPath = Join-Path $script:TempDownloadFolder $fileName
        Get-FileFromUrl -Url $config.DownloadUrl -OutputPath $downloadPath

        # Extract
        if ($config.FlattenArchive) {
            if ($ToolName -eq 'VSCode') {
                $extractedFolder = Join-Path $script:TempDownloadFolder "$($config.FolderName)_extract"
                Expand-ArchiveFile -ArchivePath $downloadPath -DestinationPath $extractedFolder

                if (Test-Path -LiteralPath $toolPath) {
                    Remove-Item -Path $toolPath -Recurse -Force
                }
                Move-Item -Path $extractedFolder -Destination $toolPath -Force
            } else {
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
        } else {
            if (Test-Path -LiteralPath $toolPath) {
                Remove-Item -Path $toolPath -Recurse -Force
            }
            Expand-ArchiveFile -ArchivePath $downloadPath -DestinationPath $toolPath
        }

        Write-Log "Installed to: $toolPath"

        # Post-install script
        if ($config.PostInstallScript) {
            Write-Log "Running post-install configuration..."
            & $config.PostInstallScript $toolPath
        }

        # Update PATH
        $pathsToAdd = @()
        if ($config.PathSubfolder) {
            $pathsToAdd += Join-Path $toolPath $config.PathSubfolder
        } else {
            $pathsToAdd += $toolPath
        }
        
        if ($config.AdditionalPaths) {
            foreach ($additionalPath in $config.AdditionalPaths) {
                $fullPath = Join-Path $toolPath $additionalPath
                # Only add if it's a directory (not a file like bash.exe)
                if (Test-Path -LiteralPath $fullPath -PathType Container) {
                    $pathsToAdd += $fullPath
                }
            }
        }
        
        Update-UserPath -Paths $pathsToAdd
        Write-Log "$($config.Name) installation complete"
    }

    function Remove-DownloadedFiles {
        [CmdletBinding()]
        param()

        if ($script:TempDownloadFolder -and (Test-Path -LiteralPath $script:TempDownloadFolder)) {
            Remove-Item -Path $script:TempDownloadFolder -Recurse -Force -ErrorAction SilentlyContinue
            Write-Log "Cleaned up temporary files"
        }
    }
}

process {
    try {
        Write-Log "=== Development Tools Installer ==="
        Write-Log "Installation Location: $Location"
        Write-Host ""

        Initialize-Environment

        # Determine which tools to install
        $toolsToInstall = if ($Tools -contains 'All') {
            @('Node', 'Git', 'Python', 'VSCode', 'ClaudeCode')  # Specific order: Git before ClaudeCode
        } else {
            # Ensure Git comes before ClaudeCode if both are requested
            $orderedTools = @()
            if ($Tools -contains 'Git') { $orderedTools += 'Git' }
            foreach ($tool in $Tools) {
                if ($tool -ne 'Git' -and $tool -ne 'ClaudeCode') {
                    $orderedTools += $tool
                }
            }
            if ($Tools -contains 'ClaudeCode') {
                if($Tools -notcontains 'Git') # if claudecode is requested but not Git, add Git as well (prereq)
                { $orderedTools += 'Git' }
                $orderedTools += 'ClaudeCode'
            }
            $orderedTools
        }

        Write-Log "Tools to process: $($toolsToInstall -join ', ')"
        Write-Host ""

        # Install each tool
        foreach ($tool in $toolsToInstall) {
            try {
                # Special check for ClaudeCode - ensure Git is installed first
                if ($tool -eq 'ClaudeCode') {
                    $gitStatus = Test-ToolInstalled -ToolName 'Git'
                    if (-not $gitStatus.IsInstalledAnywhere) {
                        Write-Log "WARNING: ClaudeCode requires Git to be installed first. Skipping ClaudeCode." -Level Warning
                        continue
                    }
                    
                    # Verify CLAUDE_CODE_GIT_BASH_PATH is set
                    $gitBashPath = [Environment]::GetEnvironmentVariable("CLAUDE_CODE_GIT_BASH_PATH", "User")
                    if (-not $gitBashPath -or -not (Test-Path -LiteralPath $gitBashPath)) {
                        Write-Log "WARNING: CLAUDE_CODE_GIT_BASH_PATH not properly set. Skipping ClaudeCode." -Level Warning
                        Write-Log "Please run the script again after Git installation completes." -Level Warning
                        continue
                    }
                }
                
                Install-Tool -ToolName $tool
                Write-Host ""
            }
            catch {
                Write-Log "Failed to install $tool : $_" -Level Error
                Write-Log "Continuing with remaining tools..." -Level Warning
                Write-Host ""
            }
        }

        Write-Log "=== Installation Summary ==="
        foreach ($tool in $toolsToInstall) {
            $status = Test-ToolInstalled -ToolName $tool
            $config = $script:ToolConfigs[$tool]
            
            if ($status.IsInstalledAnywhere) {
                Write-Log "[OK] $($config.Name) - Installed" -Level Success
            } else {
                # Special case for VSCode - check system installation too
                if ($tool -eq 'VSCode') {
                    $systemVSCode = Test-VSCodeSystemInstalled
                    if ($systemVSCode.IsInstalled) {
                        Write-Log "[OK] $($config.Name) - Installed (System)" -Level Success
                        continue
                    }
                }
                Write-Log "[--] $($config.Name) - Not Installed" -Level Warning
            }
        }
        
        Write-Host ""
        Write-Log "=== Installation Complete ===" -Level Success
        Write-Log "IMPORTANT: Restart your terminal or PowerShell session to use the newly installed tools"
        Write-Host ""
    }
    catch {
        Write-Log "Installation failed: $_" -Level Error
        throw
    }
    finally {
        Remove-DownloadedFiles
    }
}

end {}