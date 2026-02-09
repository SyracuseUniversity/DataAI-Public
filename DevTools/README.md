# Dev Tools Installer

PowerShell script to automatically download, install, and configure portable development tools to **OneDrive Apps-SU (default) or Local Apps-SU** folder.

## Features

- Downloads portable/embeddable versions of dev tools
- Auto-detects system architecture (x64 or ARM64) and downloads appropriate installers
- Installs to architecture-specific subdirectories to prevent conflicts on shared OneDrive
- Pre-installation checks detect existing installations in both locations
- Automatically configures USER PATH environment variables
- Cleans up installation files after completion
- Modular design - easy to add new tools
- Idempotent - safe to run multiple times

## Usage

```powershell
# Install all tools to OneDrive (default)
.\Install-DevTools.ps1

# Install all tools locally
.\Install-DevTools.ps1 -Location Local

# Install specific tools
.\Install-DevTools.ps1 -Tools 'Node','Git'

# Skip PATH updates
.\Install-DevTools.ps1 -SkipPathUpdate

# Silent mode (errors only)
.\Install-DevTools.ps1 -Quiet
```

## Supported Tools

| Tool | Version |
|------|---------|
| **Node.js** | 24.12.0 |
| **Git Portable** | 2.52.0 |
| **Python Embeddable** | 3.14.3 |
| **VS Code Portable** | Latest |
| **Claude Code** | Latest |

## Architecture Support

The script automatically detects your system architecture and downloads the appropriate installers. Supported architectures:

- **AMD64** (x64) - Standard Intel/AMD 64-bit systems
- **ARM64** - Windows on ARM (Surface Pro X, Copilot+ PCs, etc.)

Tools are installed into architecture-specific subdirectories:

```
Apps-SU\
├── AMD64\
│   ├── Node\
│   ├── PortableGit\
│   ├── Python\
│   └── VSCode\
└── ARM64\
    ├── Node\
    ├── PortableGit\
    ├── Python\
    └── VSCode\
```

This prevents conflicts when OneDrive syncs across devices with different architectures.

## Installation Locations

### OneDrive (Default)
Tools install to `%OneDrive%\Apps-SU\[arch]\<ToolName>` for automatic sync across devices.

### Local
Tools install to `%USERPROFILE%\Apps-SU\[arch]\<ToolName>` for machine-specific installation.

### Claude Code Exception
Claude Code always installs to `%USERPROFILE%\.local\bin` regardless of the `-Location` parameter.

## Special Configurations

### Git + Claude Code Integration

When Git is installed, the script automatically sets the `CLAUDE_CODE_GIT_BASH_PATH` environment variable to point to Git Bash. This enables Claude Code to use Git Bash for shell operations.

Example paths:
```
# OneDrive on AMD64
CLAUDE_CODE_GIT_BASH_PATH=%OneDrive%\Apps-SU\AMD64\PortableGit\bin\bash.exe

# Local on ARM64
CLAUDE_CODE_GIT_BASH_PATH=%USERPROFILE%\Apps-SU\ARM64\PortableGit\bin\bash.exe
```

**Claude Code Requirements:**
- Git must be installed first (script enforces this order automatically)
- Environment variables are updated in-session to avoid requiring a restart

### ARM64 Claude Code Compatibility

On ARM64 systems, Claude Code runs via x64 emulation. The script automatically:
1. Downloads the x64 version of Claude Code
2. Sets a Windows registry compatibility flag (`ARM64HIDEAVX`) for smooth emulation
3. Configures the executable at `HKCU:\Software\Microsoft\Windows NT\CurrentVersion\AppCompatFlags\Layers`

## Installation Workflow

1. **Detect architecture** - Determines AMD64 or ARM64
2. **Initialize tool configurations** - Sets architecture-appropriate download URLs
3. **Check if already installed** - Scans both OneDrive and Local locations
4. **Download** - Fetches from configured URL
5. **Extract** - Unzips to temporary location
6. **Install** - Moves to target directory
7. **Post-install** - Runs tool-specific configuration (if defined)
8. **Update PATH** - Adds tool directories to USER PATH
9. **Cleanup** - Removes temporary files

## Adding New Tools

### 1. Add Tool Configuration

In the `Initialize-ToolConfigs` function, add architecture-specific URLs and configuration:

```powershell
function Initialize-ToolConfigs {
    param([bool]$IsArm64)

    if ($IsArm64) {
        $newToolUrl = 'https://example.com/tool-arm64.zip'
    } else {
        $newToolUrl = 'https://example.com/tool-x64.zip'
    }

    $script:ToolConfigs = @{
        # ... existing tools ...
        
        NewTool = @{
            Name = 'Tool Display Name'
            DownloadUrl = $newToolUrl
            FolderName = 'ToolName'
            PathSubfolder = ''
            AdditionalPaths = @()
            FlattenArchive = $false
            UseOfficialInstaller = $false
            ExecutablesToCheck = @("tool.exe")
            PostInstallScript = $null
        }
    }
}
```

### Configuration Properties

| Property | Type | Description |
|----------|------|-------------|
| `Name` | String | Display name for logging |
| `DownloadUrl` | String | Direct download URL |
| `FolderName` | String | Installation folder name under Apps-SU\[arch] |
| `PathSubfolder` | String | Subfolder to add to PATH (empty = root folder) |
| `AdditionalPaths` | Array | Additional subfolders to add to PATH |
| `FlattenArchive` | Boolean | If true, extract nested folder to target |
| `UseOfficialInstaller` | Boolean | If true, use tool's official installation method |
| `ExecutablesToCheck` | Array | Executables to verify installation |
| `PostInstallScript` | ScriptBlock | Optional post-install configuration |

### 2. Add Post-Install Script (Optional)

```powershell
PostInstallScript = {
    param($ToolPath)
    
    # Create directories
    $configDir = Join-Path $ToolPath "config"
    New-Item -Path $configDir -ItemType Directory -Force | Out-Null
    
    # Set environment variables
    [Environment]::SetEnvironmentVariable("TOOL_HOME", $ToolPath, "User")
}
```

### 3. Update ValidateSet

Add the tool name to the parameter validation:

```powershell
[ValidateSet('Node', 'Git', 'Python', 'VSCode', 'ClaudeCode', 'NewTool', 'All')]
```

## Key Functions

| Function | Description |
|----------|-------------|
| `Get-SystemArchitecture` | Detects CPU architecture (AMD64/ARM64) |
| `Initialize-ToolConfigs` | Sets up tool configurations based on architecture |
| `Initialize-Environment` | Resolves paths and creates directories |
| `Test-ToolInstalled` | Checks for existing installations |
| `Test-VSCodeSystemInstalled` | Detects system VS Code installation |
| `Test-PythonSystemInstalled` | Detects system Python (checks for `py.exe`) |
| `Install-Tool` | Generic installation handler |
| `Install-ClaudeCodeOfficial` | Claude Code-specific installer |
| `Set-ClaudeCodeRegistryEntry` | ARM64 compatibility registry settings |
| `Get-FileFromUrl` | Downloads files with progress |
| `Expand-ArchiveFile` | Extracts ZIP or self-extracting archives |
| `Update-UserPath` | Adds directories to USER PATH |

## Troubleshooting

**Execution Policy Error**
This problem typically arises when downloaded from the web (as opposed to cloning the repo via Git)
When downloaded from the web, set the Execution Policy to Bypass for the file/location.
Another possible solution could be unblocking the file.
```powershell
Set-ExecutionPolicy -ExecutionPolicy Bypass -File .\Install-DevTools.ps1
```

**Unsupported Architecture**  
The script only supports AMD64 and ARM64. 32-bit systems are not supported.

**PATH not updated**  
Restart your terminal or PowerShell session.

**OneDrive not found**  
The script checks `OneDriveCommercial` and `OneDrive` environment variables. Use `-Location Local` if OneDrive is unavailable.

**Download fails**  
Verify internet connectivity. Some corporate networks may block downloads.

**Extraction fails**  
Supported formats: ZIP and self-extracting EXE (7z syntax).

**Claude Code issues on ARM64**  
The script configures registry compatibility settings automatically. If issues persist, verify the registry entry at:
```
HKCU:\Software\Microsoft\Windows NT\CurrentVersion\AppCompatFlags\Layers
```

## Design Principles

1. **Single Script** - One script handles all architectures automatically
2. **Configuration over Code** - Tool behavior defined in hashtables
3. **Idempotent** - Safe to run multiple times
4. **Minimal Dependencies** - Requires only PowerShell 5.1+
5. **User Scope** - All changes are user-level, no admin required

## License

Internal use only - Syracuse University ITS.
