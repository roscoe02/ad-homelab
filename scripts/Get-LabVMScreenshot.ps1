<#
.SYNOPSIS
    Saves a PNG of what a lab VM's screen is showing right now, using Hyper-V's thumbnail API.
    Handy for checking an unattended install's progress and for README screenshots.

.EXAMPLE
    .\Get-LabVMScreenshot.ps1 -Name DC01 -OutFile ..\screenshots\dc01-desktop.png
#>
param(
    [Parameter(Mandatory)][string]$Name,
    [Parameter(Mandatory)][string]$OutFile,
    [int]$Width = 1024,
    [int]$Height = 768
)
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Drawing

$ns  = 'root\virtualization\v2'
$vm  = Get-CimInstance -Namespace $ns -ClassName Msvm_ComputerSystem -Filter "ElementName='$Name'"
$svc = Get-CimInstance -Namespace $ns -ClassName Msvm_VirtualSystemManagementService
$settings = Get-CimAssociatedInstance -InputObject $vm -ResultClassName Msvm_VirtualSystemSettingData |
    Where-Object VirtualSystemType -eq 'Microsoft:Hyper-V:System:Realized'

$r = Invoke-CimMethod -InputObject $svc -MethodName GetVirtualSystemThumbnailImage -Arguments @{
    TargetSystem = $settings; WidthPixels = [uint16]$Width; HeightPixels = [uint16]$Height
}
if (-not $r.ImageData) { throw "No screen image from $Name (is it running?)" }

# Hyper-V returns raw 16-bit RGB565 pixels; wrap them in a bitmap and save as PNG.
$bmp  = New-Object Drawing.Bitmap($Width, $Height, [Drawing.Imaging.PixelFormat]::Format16bppRgb565)
$lock = $bmp.LockBits((New-Object Drawing.Rectangle(0, 0, $Width, $Height)), 'WriteOnly', $bmp.PixelFormat)
# Copy exactly width x height x 2 bytes (Hyper-V adds a few trailing bytes after the pixels).
[Runtime.InteropServices.Marshal]::Copy([byte[]]$r.ImageData, 0, $lock.Scan0, $Width * $Height * 2)
$bmp.UnlockBits($lock)
$OutFile = [IO.Path]::GetFullPath($OutFile)
$bmp.Save($OutFile, [Drawing.Imaging.ImageFormat]::Png)
$bmp.Dispose()
$OutFile
