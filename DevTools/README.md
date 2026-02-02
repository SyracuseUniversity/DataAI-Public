# Dev Tools Installer

PowerShell script to automatically download, install, and configure portable development tools to **OneDrive Apps-SU (default) or Local Apps-SU** folder.

## Features

- Downloads portable/embeddable versions of dev tools
- Installs to `OneDrive\Apps-SU\<ToolName>` (default) or `%USERPROFILE%\Apps-SU\<ToolName>` (local)
- **Pre-installation checks** - Detects existing installations in both locations
- Automatically configures USER PATH environment variables
- Cleans up installation files after completion
- Modular design - easy to add new tools
- Idempotent - safe to run multiple times
- Auto-extracts filenames from download URLs

## Usage
```powershell
# Install all tools to OneDrive (default)
.\Install-DevTools-x64.ps1

# Install all tools locally
.\Install-DevTools-x64.ps1 -Location Local

# Install specific tools
.\Install-DevTools-x64.ps1 -Tools 'Node','Git'

# Skip PATH updates
.\Install-DevTools-x64.ps1 -SkipPathUpdate

# Silent mode (errors only)
.\Install-DevTools-x64.ps1 -Quiet
```

## Supported Tools

- **Node.js** 24.12.0 (x64)
- **Git Portable** 2.52.0
- **Python Embeddable** 3.13.1
- **VS Code Portable** (Latest)
- **Claude Code** (Latest) - *Always installs locally*

## Installation Locations

### OneDrive (Default)
Tools install to `%OneDrive%\Apps-SU\<ToolName>` for automatic sync across devices.

### Local
Tools install to `%USERPROFILE%\Apps-SU\<ToolName>` for machine-specific installation.

### Claude Code Exception
**Note:** Claude Code always installs to `%USERPROFILE%\.local\bin` regardless of `-Location` parameter.

## Special Configurations

### Git + Claude Code Integration

When Git is installed, the script automatically sets the `CLAUDE_CODE_GIT_BASH_PATH` environment variable to point to Git Bash. This enables Claude Code to use Git Bash for shell operations.

**OneDrive:**
```
CLAUDE_CODE_GIT_BASH_PATH=%OneDrive%\Apps-SU\Git\bin\bash.exe
```

**Local:**
```
CLAUDE_CODE_GIT_BASH_PATH=%USERPROFILE%\Apps-SU\Git\bin\bash.exe
```

This integration happens automatically when installing Git - no manual configuration needed.

**Claude Code Requirements:**
- Git must be installed first (script enforces order)
- Gets environment variable update while in-session, to prevent needing to launch a new session

## Installation Structure

**OneDrive:**
```
%OneDrive%\Apps-SU\
├── Node\
├── Git\
├── Python\
└── VSCode\

%USERPROFILE%\.local\bin\
└── claude.exe
```

**Local:**
```
%USERPROFILE%\Apps-SU\
├── Node\
├── Git\
├── Python\
└── VSCode\

%USERPROFILE%\.local\bin\
└── claude.exe
```

## Architecture

The script uses a generic `Install-Tool` function that processes tool configurations. All tools share the same installation workflow:

1. **Check if already installed** - Scans both OneDrive and Local locations
2. Download from configured URL
3. Extract to temporary location
4. Move/flatten to target directory
5. Run post-install script (if defined)
6. Update USER PATH
7. Cleanup temporary files

## Adding New Tools

### 1. Add Tool Configuration
```powershell
$script:ToolConfigs = @{
    # ... existing tools ...
    
    NewTool = @{
        Name = 'Tool Display Name'              # For logging output
        DownloadUrl = 'https://example.com/tool.zip'  # Filename auto-extracted from URL
        FolderName = 'ToolName'                 # Folder under Apps-SU
        PathSubfolder = ''                      # Empty = add root to PATH, or specify subfolder
        AdditionalPaths = @()                   # Other subfolders to add to PATH
        FlattenArchive = $false                 # True = extract and move nested folder
        UseOfficialInstaller = $false           # True for tools with custom installers
        ExecutablesToCheck = @("tool.exe")      # Executables to verify installation
        PostInstallScript = $null               # Optional configuration scriptblock
    }
}
```

### Configuration Properties

| Property | Type | Description |
|----------|------|-------------|
| `Name` | String | Display name for logging output |
| `DownloadUrl` | String | Direct download URL (filename auto-extracted) |
| `FolderName` | String | Installation folder name under Apps-SU |
| `PathSubfolder` | String | Subfolder to add to PATH (empty string = use root folder) |
| `AdditionalPaths` | Array | Additional subfolders to add to PATH |
| `FlattenArchive` | Boolean | If true, extract to temp then move first subfolder to target |
| `UseOfficialInstaller` | Boolean | If true, use tool's official installation method |
| `ExecutablesToCheck` | Array | List of executables to verify for installation detection |
| `PostInstallScript` | ScriptBlock | Optional custom configuration script that runs after extraction |

### 2. Post-Install Script (Optional)

If the tool requires special configuration after extraction:
```powershell
PostInstallScript = {
    param($ToolPath)
    
    # Create directories
    $subdir = Join-Path $ToolPath "config"
    New-Item -Path $subdir -ItemType Directory -Force | Out-Null
    
    # Modify configuration files
    $configFile = Join-Path $ToolPath "settings.conf"
    Set-Content -Path $configFile -Value "key=value"
    
    # Set environment variables
    [Environment]::SetEnvironmentVariable("TOOL_HOME", $ToolPath, "User")
}
```

**Example: Git sets CLAUDE_CODE_GIT_BASH_PATH**
```powershell
Git = @{
    # ... other config ...
    PostInstallScript = {
        param($ToolPath)
        $bashPath = Join-Path $ToolPath "bin\bash.exe"
        if (Test-Path -LiteralPath $bashPath) {
            [Environment]::SetEnvironmentVariable("CLAUDE_CODE_GIT_BASH_PATH", $bashPath, "User")
        }
    }
}
```

### 3. Update ValidateSet

Add the tool name to the parameter validation:
```powershell
[ValidateSet('Node', 'Git', 'Python', 'VSCode', 'ClaudeCode', 'NewTool', 'All')]
```

## Examples

### Claude Code
```powershell
ClaudeCode = @{
    Name = 'Claude Code'
    DownloadUrl = $null
    FolderName = 'ClaudeCode'
    PathSubfolder = ''
    AdditionalPaths = @()
    FlattenArchive = $false
    UseOfficialInstaller = $true
    ExecutablesToCheck = @("claude.exe")
    RequiresGit = $true
}
```

### Go Programming Language
```powershell
Go = @{
    Name = 'Go'
    DownloadUrl = 'https://go.dev/dl/go1.21.5.windows-amd64.zip'
    FolderName = 'Go'
    PathSubfolder = 'bin'
    AdditionalPaths = @()
    FlattenArchive = $true
    PostInstallScript = {
        param($ToolPath)
        # Create GOPATH directory
        $goPath = Join-Path (Split-Path $ToolPath -Parent) "GoPath"
        New-Item -Path $goPath -ItemType Directory -Force | Out-Null
        [Environment]::SetEnvironmentVariable("GOPATH", $goPath, "User")
        
        # Create GOPATH\bin and add to PATH
        $goBin = Join-Path $goPath "bin"
        New-Item -Path $goBin -ItemType Directory -Force | Out-Null
        
        $currentPath = [Environment]::GetEnvironmentVariable("Path", "User")
        if ($currentPath -notlike "*$goBin*") {
            [Environment]::SetEnvironmentVariable("Path", "$currentPath;$goBin", "User")
        }
    }
}
```

### Maven
```powershell
Maven = @{
    Name = 'Apache Maven'
    DownloadUrl = 'https://dlcdn.apache.org/maven/maven-3/3.9.6/binaries/apache-maven-3.9.6-bin.zip'
    FolderName = 'Maven'
    PathSubfolder = 'bin'
    AdditionalPaths = @()
    FlattenArchive = $true
    PostInstallScript = {
        param($ToolPath)
        [Environment]::SetEnvironmentVariable("MAVEN_HOME", $ToolPath, "User")
    }
}
```

### 7-Zip
```powershell
SevenZip = @{
    Name = '7-Zip'
    DownloadUrl = 'https://www.7-zip.org/a/7z2301-x64.msi'
    FolderName = '7zip'
    PathSubfolder = ''
    AdditionalPaths = @()
    FlattenArchive = $false
}
```

## Architecture Notes

This script is for **x64 (AMD64) architecture only**. The script includes an architecture check that will fail if run on non-x64 systems.

Tool downloads are architecture-specific. Update the `DownloadUrl` in tool configurations to match your system:

- **x64/amd64**: Standard Intel/AMD 64-bit (this script) - use URLs with `x64` or `amd64`
- **ARM64**: Windows on ARM (Surface ARM, M1/M2 via Windows VM) - use URLs with `arm64` or `aarch64`
- **x86**: 32-bit (legacy) - use URLs with `x86` or `win32`

**Example: Node.js x64 (current)**
```powershell
DownloadUrl = 'https://nodejs.org/dist/v24.12.0/node-v24.12.0-win-x64.zip'
```

## Key Functions

### Install-Tool
Generic installation function that processes tool configuration and handles all standard installation steps.

### Initialize-Environment
Resolves OneDrive and Local paths, creates necessary directories.

### Test-ToolInstalled
Checks both OneDrive and Local locations for existing installations.

### Get-FileFromUrl
Downloads files with optional progress reporting.

### Expand-ArchiveFile
Extracts ZIP files or runs self-extracting EXE archives.

### Update-UserPath
Adds directories to USER PATH if not already present.

### Write-Log
Centralized logging with level support (Info, Warning, Error, Success).

## Troubleshooting

**Execution Policy Error**  
If you get an error about script execution being disabled:
```powershell
# Set execution policy for current user (recommended)
Set-ExecutionPolicy -ExecutionPolicy RemoteSigned -Scope CurrentUser
```

**PATH not updated**  
Restart your terminal or PowerShell session.

**OneDrive not found**  
Ensure OneDrive is configured. The script checks `OneDriveCommercial` and `OneDrive` environment variables. If unavailable, use `-Location Local`.

**Download fails**  
Verify internet connectivity and URL validity. Some downloads may require specific user agents or cookies.

**Extraction fails**  
Ensure the archive format is supported (ZIP or self-extracting EXE with 7z syntax).

**Permission errors**  
Run as Administrator if modifying system-level settings, though the script uses USER scope by default.

## Design Principles

1. **DRY (Don't Repeat Yourself)**: Single generic installation function handles all tools
2. **Configuration over Code**: Tool-specific behavior defined in configuration hashtables
3. **Minimal Output**: Essential logging only, optional quiet mode
4. **Error Handling**: Strict mode with proper exception propagation
5. **Idempotent**: Safe to run multiple times
6. **Self-Contained**: No external dependencies beyond PowerShell 5.1+

## License

Internal use only - Syracuse University ITS.
