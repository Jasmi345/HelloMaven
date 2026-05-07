<#
    .Synopsis
    Upgrades the version information in the register from the current Jenkins war file.
    .Description
    The purpose of this script is to update the version of Jenkins in the registry
    when the user may have upgraded the war file in place. The script probes the
    registry for information about the Jenkins install (path to war, etc.) and 
    then grabs the version information from the war to update the values in the
    registry so they match the version of the war file. 

    This will help with security scanners that look in the registry for versions
    of software and flag things when they are too low. The information in the 
    registry may be very old compared to what version of the war file is 
    actually installed on the system.
#>


# Self-elevate the script if required
if (-Not ([Security.Principal.WindowsPrincipal] [Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole] 'Administrator')) {
    # We may be running under powershell.exe or pwsh.exe, make sure we relaunch the same one.
    $Executable = [System.Diagnostics.Process]::GetCurrentProcess().MainModule.FileName
    if ([int](Get-CimInstance -Class Win32_OperatingSystem | Select-Object -ExpandProperty BuildNumber) -ge 6000) {
        # Launching with RunAs to get elevation
        $CommandLine = "-File `"" + $MyInvocation.MyCommand.Path + "`" " + $MyInvocation.UnboundArguments
        Start-Process -FilePath $Executable -Verb Runas -ArgumentList $CommandLine
        Exit
    }
}

function New-TemporaryDirectory {
    $Parent = [System.IO.Path]::GetTempPath()
    do {
        $Name = [System.IO.Path]::GetRandomFileName()
        $Item = New-Item -Path $Parent -Name $Name -ItemType "Directory" -ErrorAction SilentlyContinue
    } while (-not $Item)
    return $Item.FullName
}

function Exit-Script($Message, $Fatal = $False) {
    $ExitCode = 0
    if($Fatal) {
        Write-Error $Message
    } else {
        Write-Host $Message
    }
    Read-Host "Press ENTER to continue"
    Exit $ExitCode
}

# Let's find the location of the war file...
$JenkinsDir = Get-ItemPropertyValue -Path HKLM:\Software\Jenkins\InstalledProducts\Jenkins -Name InstallLocation -ErrorAction SilentlyContinue

if (($Null -eq $JenkinsDir) -or [String]::IsNullOrWhiteSpace($JenkinsDir)) {
    Exit-Script -Message "Jenkins does not seem to be installed. Please verify you have previously installed using the MSI installer" -Fatal $True
}

$WarPath = Join-Path $JenkinsDir "jenkins.war"
if(-Not (Test-Path $WarPath)) {
    Exit-Script -Message "Could not find war file at location found in registry, please verify Jenkins installation" -Fatal $True
}

# Get the MANIFEST.MF file from the war file to get the version of Jenkins
$TempWorkDir = New-TemporaryDirectory
$ManifestFile = Join-Path $TempWorkDir "MANIFEST.MF"
$Zip = [IO.Compression.ZipFile]::OpenRead($WarPath)
$Zip.Entries | Where-Object { $_.Name -like "MANIFEST.MF" } | ForEach-Object { [System.IO.Compression.ZipFileExtensions]::ExtractToFile($_, $ManiFestFile, $True) }
$Zip.Dispose()

$JenkinsVersion = $(Get-Content $ManiFestFile | Select-String -Pattern "^Jenkins-Version:\s*(.*)" | ForEach-Object { $_.Matches } | ForEach-Object { $_.Groups[1].Value } | Select-Object -First 1)
Remove-Item -Path $ManifestFile

# Convert the Jenkins version into what should be in the registry
$VersionItems = $JenkinsVersion.Split(".") | ForEach-Object { [int]::Parse($_) }

# Use the same encoding algorithm as the installer to encode the version into the correct format 
$RegistryEncodedVersion = 0
$Major = $VersionItems[0]
if ($VersionItems.Length -le 2) {
    $Minor = 0
    if (($VersionItems.Length -gt 1) -and ($VersionItems[1] -gt 255)) {
        $Minor = $VersionItems[1]
        $RegistryEncodedVersion = $RegistryEncodedVersion -bor ((($Major -band 0xff) -shl 24) -bor 0x00ff0000 -bor (($Minor * 10) -band 0x0000ffff))
    }
    else {
        $RegistryEncodedVersion = $RegistryEncodedVersion -bor (($Major -band 0xff) -shl 24)
    }
}
else {
    $Minor = $VersionItems[1]
    if ($Minor -gt 255) {
        $RegistryEncodedVersion = $RegistryEncodedVersion -bor ((($Major -band 0xff) -shl 24) -bor 0x00ff0000 -bor ((($Minor * 10) + $VersionItems[2]) -band 0x0000ffff))
    }
    else {
        $RegistryEncodedVersion = $RegistryEncodedVersion -bor ((($Major -band 0xff) -shl 24) -bor (($Minor -band 0xff) -shl 16) -bor ($VersionItems[2] -band 0x0000ffff))
    }
}

$ProductName = "Jenkins $JenkinsVersion"

# Find the registry key for Jenkins in the Installer\Products area and CurrentVersion\Uninstall
$JenkinsProductsRegistryKey = Get-ChildItem -Path HKLM:\SOFTWARE\Classes\Installer\Products  | Where-Object { $_.GetValue("ProductName", "").StartsWith("Jenkins") }

$JenkinsUninstallRegistryKey = Get-ChildItem -Path HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall  | Where-Object { $_.GetValue("DisplayName", "").StartsWith("Jenkins") }

if (($Null -eq $JenkinsProductsRegistryKey) -or ($Null -eq $JenkinsUninstallRegistryKey)) {
    Exit-Script -Message "Could not find the product information for Jenkins" -Fatal $True
}

# Update the Installer\Products area
$RegistryPath = $JenkinsProductsRegistryKey.Name.Substring($JenkinsProductsRegistryKey.Name.IndexOf("\"))

$OldProductName = $JenkinsProductsRegistryKey.GetValue("ProductName", "")
if ($OldProductName -ne $ProductName) {
    Set-ItemProperty -Path HKLM:$RegistryPath -Name "ProductName" -Type String -Value $ProductName 
}

$OldVersion = $JenkinsProductsRegistryKey.GetValue("Version", 0)
if ($OldVersion -ne $RegistryEncodedVersion) {
    Set-ItemProperty -Path HKLM:$RegistryPath -Name "Version" -Type DWord -Value $RegistryEncodedVersion
}

# Update the Uninstall area
$RegistryPath = $JenkinsUninstallRegistryKey.Name.Substring($JenkinsUninstallRegistryKey.Name.IndexOf("\"))
$OldDisplayName = $JenkinsUninstallRegistryKey.GetValue("DisplayName", "")
if ($OldDisplayName -ne $ProductName) {
    Set-ItemProperty -Path HKLM:$RegistryPath -Name "DisplayName" -Type String -Value $ProductName
}

$OldDisplayVersion = $JenkinsUninstallRegistryKey.GetValue("DisplayVersion", "")
$DisplayVersion = "{0}.{1}.{2}" -f ($RegistryEncodedVersion -shr 24), (($RegistryEncodedVersion -shr 16) -band 0xff), ($RegistryEncodedVersion -band 0xffff)
if ($OldDisplayVersion -ne $DisplayVersion) {
    Set-ItemProperty -Path HKLM:$RegistryPath -Name "DisplayVersion" -Type String -Value $DisplayVersion
}

$OldVersion = $JenkinsUninstallRegistryKey.GetValue("Version", 0)
if ($OldVersion -ne $RegistryEncodedVersion) {
    Set-ItemProperty -Path HKLM:$RegistryPath -Name "Version" -Type DWord -Value $RegistryEncodedVersion
}

$OldVersionMajor = $JenkinsUninstallRegistryKey.GetValue("VersionMajor", 0)
$VersionMajor = $RegistryEncodedVersion -shr 24
if ($OldVersionMajor -ne $VersionMajor) {

    Set-ItemProperty -Path HKLM:$RegistryPath -Name "VersionMajor" -Type DWord -Value $VersionMajor
}

$OldVersionMinor = $JenkinsUninstallRegistryKey.GetValue("VersionMinor", 0)
$VersionMinor = ($RegistryEncodedVersion -shr 16) -band 0xff
if ($OldVersionMinor -ne $VersionMinor) {
    Set-ItemProperty -Path HKLM:$RegistryPath -Name "VersionMinor" -Type DWord -Value $VersionMinor
}

Read-Host "Press ENTER to continue"

# SIG # Begin signature block
# MIIp/gYJKoZIhvcNAQcCoIIp7zCCKesCAQExDzANBglghkgBZQMEAgEFADB5Bgor
# BgEEAYI3AgEEoGswaTA0BgorBgEEAYI3AgEeMCYCAwEAAAQQH8w7YFlLCE63JNLG
# KX7zUQIBAAIBAAIBAAIBAAIBADAxMA0GCWCGSAFlAwQCAQUABCDbyeWzg9oNvcU/
# j3Q0982rRxp4werHyv0Gv0YLxmkVkaCCDlowggawMIIEmKADAgECAhAIrUCyYNKc
# TJ9ezam9k67ZMA0GCSqGSIb3DQEBDAUAMGIxCzAJBgNVBAYTAlVTMRUwEwYDVQQK
# EwxEaWdpQ2VydCBJbmMxGTAXBgNVBAsTEHd3dy5kaWdpY2VydC5jb20xITAfBgNV
# BAMTGERpZ2lDZXJ0IFRydXN0ZWQgUm9vdCBHNDAeFw0yMTA0MjkwMDAwMDBaFw0z
# NjA0MjgyMzU5NTlaMGkxCzAJBgNVBAYTAlVTMRcwFQYDVQQKEw5EaWdpQ2VydCwg
# SW5jLjFBMD8GA1UEAxM4RGlnaUNlcnQgVHJ1c3RlZCBHNCBDb2RlIFNpZ25pbmcg
# UlNBNDA5NiBTSEEzODQgMjAyMSBDQTEwggIiMA0GCSqGSIb3DQEBAQUAA4ICDwAw
# ggIKAoICAQDVtC9C0CiteLdd1TlZG7GIQvUzjOs9gZdwxbvEhSYwn6SOaNhc9es0
# JAfhS0/TeEP0F9ce2vnS1WcaUk8OoVf8iJnBkcyBAz5NcCRks43iCH00fUyAVxJr
# Q5qZ8sU7H/Lvy0daE6ZMswEgJfMQ04uy+wjwiuCdCcBlp/qYgEk1hz1RGeiQIXhF
# LqGfLOEYwhrMxe6TSXBCMo/7xuoc82VokaJNTIIRSFJo3hC9FFdd6BgTZcV/sk+F
# LEikVoQ11vkunKoAFdE3/hoGlMJ8yOobMubKwvSnowMOdKWvObarYBLj6Na59zHh
# 3K3kGKDYwSNHR7OhD26jq22YBoMbt2pnLdK9RBqSEIGPsDsJ18ebMlrC/2pgVItJ
# wZPt4bRc4G/rJvmM1bL5OBDm6s6R9b7T+2+TYTRcvJNFKIM2KmYoX7BzzosmJQay
# g9Rc9hUZTO1i4F4z8ujo7AqnsAMrkbI2eb73rQgedaZlzLvjSFDzd5Ea/ttQokbI
# YViY9XwCFjyDKK05huzUtw1T0PhH5nUwjewwk3YUpltLXXRhTT8SkXbev1jLchAp
# QfDVxW0mdmgRQRNYmtwmKwH0iU1Z23jPgUo+QEdfyYFQc4UQIyFZYIpkVMHMIRro
# OBl8ZhzNeDhFMJlP/2NPTLuqDQhTQXxYPUez+rbsjDIJAsxsPAxWEQIDAQABo4IB
# WTCCAVUwEgYDVR0TAQH/BAgwBgEB/wIBADAdBgNVHQ4EFgQUaDfg67Y7+F8Rhvv+
# YXsIiGX0TkIwHwYDVR0jBBgwFoAU7NfjgtJxXWRM3y5nP+e6mK4cD08wDgYDVR0P
# AQH/BAQDAgGGMBMGA1UdJQQMMAoGCCsGAQUFBwMDMHcGCCsGAQUFBwEBBGswaTAk
# BggrBgEFBQcwAYYYaHR0cDovL29jc3AuZGlnaWNlcnQuY29tMEEGCCsGAQUFBzAC
# hjVodHRwOi8vY2FjZXJ0cy5kaWdpY2VydC5jb20vRGlnaUNlcnRUcnVzdGVkUm9v
# dEc0LmNydDBDBgNVHR8EPDA6MDigNqA0hjJodHRwOi8vY3JsMy5kaWdpY2VydC5j
# b20vRGlnaUNlcnRUcnVzdGVkUm9vdEc0LmNybDAcBgNVHSAEFTATMAcGBWeBDAED
# MAgGBmeBDAEEATANBgkqhkiG9w0BAQwFAAOCAgEAOiNEPY0Idu6PvDqZ01bgAhql
# +Eg08yy25nRm95RysQDKr2wwJxMSnpBEn0v9nqN8JtU3vDpdSG2V1T9J9Ce7FoFF
# UP2cvbaF4HZ+N3HLIvdaqpDP9ZNq4+sg0dVQeYiaiorBtr2hSBh+3NiAGhEZGM1h
# mYFW9snjdufE5BtfQ/g+lP92OT2e1JnPSt0o618moZVYSNUa/tcnP/2Q0XaG3Ryw
# YFzzDaju4ImhvTnhOE7abrs2nfvlIVNaw8rpavGiPttDuDPITzgUkpn13c5Ubdld
# AhQfQDN8A+KVssIhdXNSy0bYxDQcoqVLjc1vdjcshT8azibpGL6QB7BDf5WIIIJw
# 8MzK7/0pNVwfiThV9zeKiwmhywvpMRr/LhlcOXHhvpynCgbWJme3kuZOX956rEnP
# LqR0kq3bPKSchh/jwVYbKyP/j7XqiHtwa+aguv06P0WmxOgWkVKLQcBIhEuWTatE
# QOON8BUozu3xGFYHKi8QxAwIZDwzj64ojDzLj4gLDb879M4ee47vtevLt/B3E+bn
# KD+sEq6lLyJsQfmCXBVmzGwOysWGw/YmMwwHS6DTBwJqakAwSEs0qFEgu60bhQji
# WQ1tygVQK+pKHJ6l/aCnHwZ05/LWUpD9r4VIIflXO7ScA+2GRfS0YW6/aOImYIbq
# yK+p/pQd52MbOoZWeE4wggeiMIIFiqADAgECAhADJPGbkeizM3ep7tjv4Oh/MA0G
# CSqGSIb3DQEBCwUAMGkxCzAJBgNVBAYTAlVTMRcwFQYDVQQKEw5EaWdpQ2VydCwg
# SW5jLjFBMD8GA1UEAxM4RGlnaUNlcnQgVHJ1c3RlZCBHNCBDb2RlIFNpZ25pbmcg
# UlNBNDA5NiBTSEEzODQgMjAyMSBDQTEwHhcNMjMwNDAzMDAwMDAwWhcNMjYwNTE2
# MjM1OTU5WjCBqTELMAkGA1UEBhMCVVMxETAPBgNVBAgTCERlbGF3YXJlMRMwEQYD
# VQQHEwpXaWxtaW5ndG9uMTgwNgYDVQQKEy9DREYgQmluYXJ5IFByb2plY3QgYSBT
# ZXJpZXMgb2YgTEYgUHJvamVjdHMsIExMQzE4MDYGA1UEAxMvQ0RGIEJpbmFyeSBQ
# cm9qZWN0IGEgU2VyaWVzIG9mIExGIFByb2plY3RzLCBMTEMwggIiMA0GCSqGSIb3
# DQEBAQUAA4ICDwAwggIKAoICAQDfqgZcXDJTB5793QlJS7n18mEi24oIQM8oBEYa
# 9swJt4M/pvIyWSSKj0FIKtqOzJQAlaf1cyxOlAisOmsc6K1CCFnnFKvIlyNjRCso
# uoanpbp2Tm0YeoLZhnb71IgWKxcI0Rwida9L+sAsHvsmhWjBQiIs0iAn566nk5UM
# tucGtA4IIK516JmHP8oJxxTgB1X7epupLf0InZeCzd+p36Ct77aCh/wXAnimeBl+
# GrZ+fzHZLCxl7BYk5USiRHVAPJ/nyhqJuOdkHToplFApJBYQYAOhve4S8HWmyqKt
# oBCzeSOQPRYCLQ2bYAo/C23ldMEzEVXd1hju59ZpR4cbJOI4Uhh9tGy0NuzSGhf0
# QdG2XEFdPux/+JW47xpfe4IEkYUq3AKIaZVKWmCZQNoBNrwEmnccYp4tBCsGWO4E
# gcp6V9uChgFpOU4d22hcOxlJjJcTMduqBIskgpoZgoL8RuFXk1P3s9LzROzgJO4F
# d2GljWwDRlut5w/eUuo+++gPmawSKN7FvjvMG3DJGVFBOphwrAGGw7BQ7zSThICJ
# F7kuEFsawCdFNScZSll7FC011U6Hf/6qy/w+lEFhEPFc9GmHO2eQlD/EiU3flXex
# 3qsT0Tagv74AwJHK8Jh6E/WRa2Skqaj3IcPIkm6aZbSPGGNujjXh1KfOGq8hZ/0K
# MUQM2wIDAQABo4ICAzCCAf8wHwYDVR0jBBgwFoAUaDfg67Y7+F8Rhvv+YXsIiGX0
# TkIwHQYDVR0OBBYEFEA4cBGhmjuHUVaxlLPntLnIMLmQMA4GA1UdDwEB/wQEAwIH
# gDATBgNVHSUEDDAKBggrBgEFBQcDAzCBtQYDVR0fBIGtMIGqMFOgUaBPhk1odHRw
# Oi8vY3JsMy5kaWdpY2VydC5jb20vRGlnaUNlcnRUcnVzdGVkRzRDb2RlU2lnbmlu
# Z1JTQTQwOTZTSEEzODQyMDIxQ0ExLmNybDBToFGgT4ZNaHR0cDovL2NybDQuZGln
# aWNlcnQuY29tL0RpZ2lDZXJ0VHJ1c3RlZEc0Q29kZVNpZ25pbmdSU0E0MDk2U0hB
# Mzg0MjAyMUNBMS5jcmwwPgYDVR0gBDcwNTAzBgZngQwBBAEwKTAnBggrBgEFBQcC
# ARYbaHR0cDovL3d3dy5kaWdpY2VydC5jb20vQ1BTMIGUBggrBgEFBQcBAQSBhzCB
# hDAkBggrBgEFBQcwAYYYaHR0cDovL29jc3AuZGlnaWNlcnQuY29tMFwGCCsGAQUF
# BzAChlBodHRwOi8vY2FjZXJ0cy5kaWdpY2VydC5jb20vRGlnaUNlcnRUcnVzdGVk
# RzRDb2RlU2lnbmluZ1JTQTQwOTZTSEEzODQyMDIxQ0ExLmNydDAJBgNVHRMEAjAA
# MA0GCSqGSIb3DQEBCwUAA4ICAQA0nYhrG8FM2LQT4e18lk9EgwvuN4ic4A87ci4b
# cxSjYmuUtM2xtsq/9mYROa+7054SbvE2JKyqkvisIb/Ks9zhTSr6hMN0PTO1fKjf
# tth5vBOc7JZTZEsMRJrjZN+zmE6M0w7R67r0TVKbOBWJeUH5g/XMOPaWH8WEEF5S
# m8f2QjmFYyi9inBD5EWBuGK9q4lfda2k2hZ5AY2IddA7apZTiD9QQH3ex/biVVr2
# Zql8TC8918EDnBTwntySMtPLP+GCp416JrQGyapolwbHRDug+hQQJ7+ie8ygWr6K
# 7aAOpvleE/Wjqkl023x6djUdMDe/MbqRDzkOU83osgN9sySIEzTPj5sH+BEjOjNo
# 5jkcPMIvLMeudoweglm+llsnnJMQNLKjik6vp0Klvc3Hphs0Iqo4oEixf5QGA1Ja
# BGsu/nBx94qGJg7zPmCDkTVR/kpbCywrpCnq5CDPMQjR8TkadzG9OUR/nr+YXDX8
# lfzH7MRxoh3dEOh10wduINeGf6FHJhNVcrf4Mts5oLFXLbKTZTPeJ+Vni2BVNOIA
# roQvMFYjIx8YZY0Z2n2xxtePSPh8fPkgH+eeAO/zvZEX0dIz+FudOpsrhO7MTrGl
# XZ5roSeSVy+ZqVngRkJaMCtsf0rd/4uRfxjnsdWWMaiBH4vDa/uI+JjwaPGMRH9C
# +U9y3DGCGvowghr2AgEBMH0waTELMAkGA1UEBhMCVVMxFzAVBgNVBAoTDkRpZ2lD
# ZXJ0LCBJbmMuMUEwPwYDVQQDEzhEaWdpQ2VydCBUcnVzdGVkIEc0IENvZGUgU2ln
# bmluZyBSU0E0MDk2IFNIQTM4NCAyMDIxIENBMQIQAyTxm5HoszN3qe7Y7+DofzAN
# BglghkgBZQMEAgEFAKCB1DAZBgkqhkiG9w0BCQMxDAYKKwYBBAGCNwIBBDAcBgor
# BgEEAYI3AgELMQ4wDAYKKwYBBAGCNwIBFTAvBgkqhkiG9w0BCQQxIgQgSryF4dcs
# 7+G2EseArPHZ/z/KN04sbkO7SZGsfdIrWUgwaAYKKwYBBAGCNwIBDDFaMFigQIA+
# AEoAZQBuAGsAaQBuAHMAIABBAHUAdABvAG0AYQB0AGkAbwBuACAAUwBlAHIAdgBl
# AHIAIAAyAC4ANQA2ADGhFIASaHR0cHM6Ly9qZW5raW5zLmlvMA0GCSqGSIb3DQEB
# AQUABIICANjHRihyT4bZRBBlQh1PMgfC4pSA1BNhPZhd5TOPOUD7p6Dc84/xlT28
# iST2lV+UILaynq8ZQuYm+Avr2PhO3b/UGAOAG0qhfrh7xJXjcADwsO4eqKwaheud
# A3IDPd9LHfphPAMySufgGkMUWcvIxt5d19YSgvopJadbcLurhjTOyDwKj5tpOOSp
# +A1VPPWZscXozMKLuJdwhZ3Ak4Bcr+6TTzIeIChw4DTjSxeUjVTDSjuq1x58PShh
# PQxutq4FvXM7RZQveGFRlZhKcefZdCJzaI2jzx8CHSWQcesEUV6R9AxO9+olByiq
# YPYOrpjJLvVICCrEcVR5Sy3+TXehgOhiLIB6MBjOhSwQST+UtzJ3ge9vWiGqchAX
# Fj0QOhL9Rewy6DUlWrjEjhFSlJ6spnatHNQZiZ4uNhQEC9nq6eRAP6cwebyDSi1d
# DUyBHzzhlwXjy0AeArtwz9HGXEhoVGm0dg8/gOaaRZoVm1gp3+bzPFVox5MKfZBL
# +nWU3KyGPUGdNc9EM8JicZClqkhJ28dex7RE6knEvRlx6dYVyHB5Ar+0SaeaKGjH
# U5ZbmxYsL2ynZvsnS4CyHVqVIFLpTDhSZisCiQWjYHi3AesZjEXG2rXu3GO8J6cN
# ilYx6ORSU7rVsO5KzaYvQeV8DUR6WgdHkul26tYY5zHnzRdlQ2tfoYIXdzCCF3MG
# CisGAQQBgjcDAwExghdjMIIXXwYJKoZIhvcNAQcCoIIXUDCCF0wCAQMxDzANBglg
# hkgBZQMEAgEFADB4BgsqhkiG9w0BCRABBKBpBGcwZQIBAQYJYIZIAYb9bAcBMDEw
# DQYJYIZIAWUDBAIBBQAEIMR3fwQwAvYE1jsMFntOVwYHNIhZFZOKys7AO2lX8QBZ
# AhEAtu086LflGePT3T0O9K8h9BgPMjAyNjA0MjExODM0NDdaoIITOjCCBu0wggTV
# oAMCAQICEAqA7xhLjfEFgtHEdqeVdGgwDQYJKoZIhvcNAQELBQAwaTELMAkGA1UE
# BhMCVVMxFzAVBgNVBAoTDkRpZ2lDZXJ0LCBJbmMuMUEwPwYDVQQDEzhEaWdpQ2Vy
# dCBUcnVzdGVkIEc0IFRpbWVTdGFtcGluZyBSU0E0MDk2IFNIQTI1NiAyMDI1IENB
# MTAeFw0yNTA2MDQwMDAwMDBaFw0zNjA5MDMyMzU5NTlaMGMxCzAJBgNVBAYTAlVT
# MRcwFQYDVQQKEw5EaWdpQ2VydCwgSW5jLjE7MDkGA1UEAxMyRGlnaUNlcnQgU0hB
# MjU2IFJTQTQwOTYgVGltZXN0YW1wIFJlc3BvbmRlciAyMDI1IDEwggIiMA0GCSqG
# SIb3DQEBAQUAA4ICDwAwggIKAoICAQDQRqwtEsae0OquYFazK1e6b1H/hnAKAd/K
# N8wZQjBjMqiZ3xTWcfsLwOvRxUwXcGx8AUjni6bz52fGTfr6PHRNv6T7zsf1Y/E3
# IU8kgNkeECqVQ+3bzWYesFtkepErvUSbf+EIYLkrLKd6qJnuzK8Vcn0DvbDMemQF
# oxQ2Dsw4vEjoT1FpS54dNApZfKY61HAldytxNM89PZXUP/5wWWURK+IfxiOg8W9l
# KMqzdIo7VA1R0V3Zp3DjjANwqAf4lEkTlCDQ0/fKJLKLkzGBTpx6EYevvOi7XOc4
# zyh1uSqgr6UnbksIcFJqLbkIXIPbcNmA98Oskkkrvt6lPAw/p4oDSRZreiwB7x9y
# krjS6GS3NR39iTTFS+ENTqW8m6THuOmHHjQNC3zbJ6nJ6SXiLSvw4Smz8U07hqF+
# 8CTXaETkVWz0dVVZw7knh1WZXOLHgDvundrAtuvz0D3T+dYaNcwafsVCGZKUhQPL
# 1naFKBy1p6llN3QgshRta6Eq4B40h5avMcpi54wm0i2ePZD5pPIssoszQyF4//3D
# oK2O65Uck5Wggn8O2klETsJ7u8xEehGifgJYi+6I03UuT1j7FnrqVrOzaQoVJOee
# StPeldYRNMmSF3voIgMFtNGh86w3ISHNm0IaadCKCkUe2LnwJKa8TIlwCUNVwppw
# n4D3/Pt5pwIDAQABo4IBlTCCAZEwDAYDVR0TAQH/BAIwADAdBgNVHQ4EFgQU5Dv8
# 8jHt/f3X85FxYxlQQ89hjOgwHwYDVR0jBBgwFoAU729TSunkBnx6yuKQVvYv1Ens
# y04wDgYDVR0PAQH/BAQDAgeAMBYGA1UdJQEB/wQMMAoGCCsGAQUFBwMIMIGVBggr
# BgEFBQcBAQSBiDCBhTAkBggrBgEFBQcwAYYYaHR0cDovL29jc3AuZGlnaWNlcnQu
# Y29tMF0GCCsGAQUFBzAChlFodHRwOi8vY2FjZXJ0cy5kaWdpY2VydC5jb20vRGln
# aUNlcnRUcnVzdGVkRzRUaW1lU3RhbXBpbmdSU0E0MDk2U0hBMjU2MjAyNUNBMS5j
# cnQwXwYDVR0fBFgwVjBUoFKgUIZOaHR0cDovL2NybDMuZGlnaWNlcnQuY29tL0Rp
# Z2lDZXJ0VHJ1c3RlZEc0VGltZVN0YW1waW5nUlNBNDA5NlNIQTI1NjIwMjVDQTEu
# Y3JsMCAGA1UdIAQZMBcwCAYGZ4EMAQQCMAsGCWCGSAGG/WwHATANBgkqhkiG9w0B
# AQsFAAOCAgEAZSqt8RwnBLmuYEHs0QhEnmNAciH45PYiT9s1i6UKtW+FERp8FgXR
# GQ/YAavXzWjZhY+hIfP2JkQ38U+wtJPBVBajYfrbIYG+Dui4I4PCvHpQuPqFgqp1
# PzC/ZRX4pvP/ciZmUnthfAEP1HShTrY+2DE5qjzvZs7JIIgt0GCFD9ktx0LxxtRQ
# 7vllKluHWiKk6FxRPyUPxAAYH2Vy1lNM4kzekd8oEARzFAWgeW3az2xejEWLNN4e
# KGxDJ8WDl/FQUSntbjZ80FU3i54tpx5F/0Kr15zW/mJAxZMVBrTE2oi0fcI8VMbt
# oRAmaaslNXdCG1+lqvP4FbrQ6IwSBXkZagHLhFU9HCrG/syTRLLhAezu/3Lr00Gr
# JzPQFnCEH1Y58678IgmfORBPC1JKkYaEt2OdDh4GmO0/5cHelAK2/gTlQJINqDr6
# JfwyYHXSd+V08X1JUPvB4ILfJdmL+66Gp3CSBXG6IwXMZUXBhtCyIaehr0XkBoDI
# GMUG1dUtwq1qmcwbdUfcSYCn+OwncVUXf53VJUNOaMWMts0VlRYxe5nK+At+DI96
# HAlXHAL5SlfYxJ7La54i71McVWRP66bW+yERNpbJCjyCYG2j+bdpxo/1Cy4uPcU3
# AWVPGrbn5PhDBf3Froguzzhk++ami+r3Qrx5bIbY3TVzgiFI7Gq3zWcwgga0MIIE
# nKADAgECAhANx6xXBf8hmS5AQyIMOkmGMA0GCSqGSIb3DQEBCwUAMGIxCzAJBgNV
# BAYTAlVTMRUwEwYDVQQKEwxEaWdpQ2VydCBJbmMxGTAXBgNVBAsTEHd3dy5kaWdp
# Y2VydC5jb20xITAfBgNVBAMTGERpZ2lDZXJ0IFRydXN0ZWQgUm9vdCBHNDAeFw0y
# NTA1MDcwMDAwMDBaFw0zODAxMTQyMzU5NTlaMGkxCzAJBgNVBAYTAlVTMRcwFQYD
# VQQKEw5EaWdpQ2VydCwgSW5jLjFBMD8GA1UEAxM4RGlnaUNlcnQgVHJ1c3RlZCBH
# NCBUaW1lU3RhbXBpbmcgUlNBNDA5NiBTSEEyNTYgMjAyNSBDQTEwggIiMA0GCSqG
# SIb3DQEBAQUAA4ICDwAwggIKAoICAQC0eDHTCphBcr48RsAcrHXbo0ZodLRRF51N
# rY0NlLWZloMsVO1DahGPNRcybEKq+RuwOnPhof6pvF4uGjwjqNjfEvUi6wuim5ba
# p+0lgloM2zX4kftn5B1IpYzTqpyFQ/4Bt0mAxAHeHYNnQxqXmRinvuNgxVBdJkf7
# 7S2uPoCj7GH8BLuxBG5AvftBdsOECS1UkxBvMgEdgkFiDNYiOTx4OtiFcMSkqTtF
# 2hfQz3zQSku2Ws3IfDReb6e3mmdglTcaarps0wjUjsZvkgFkriK9tUKJm/s80Fio
# cSk1VYLZlDwFt+cVFBURJg6zMUjZa/zbCclF83bRVFLeGkuAhHiGPMvSGmhgaTzV
# yhYn4p0+8y9oHRaQT/aofEnS5xLrfxnGpTXiUOeSLsJygoLPp66bkDX1ZlAeSpQl
# 92QOMeRxykvq6gbylsXQskBBBnGy3tW/AMOMCZIVNSaz7BX8VtYGqLt9MmeOreGP
# RdtBx3yGOP+rx3rKWDEJlIqLXvJWnY0v5ydPpOjL6s36czwzsucuoKs7Yk/ehb//
# Wx+5kMqIMRvUBDx6z1ev+7psNOdgJMoiwOrUG2ZdSoQbU2rMkpLiQ6bGRinZbI4O
# Lu9BMIFm1UUl9VnePs6BaaeEWvjJSjNm2qA+sdFUeEY0qVjPKOWug/G6X5uAiynM
# 7Bu2ayBjUwIDAQABo4IBXTCCAVkwEgYDVR0TAQH/BAgwBgEB/wIBADAdBgNVHQ4E
# FgQU729TSunkBnx6yuKQVvYv1Ensy04wHwYDVR0jBBgwFoAU7NfjgtJxXWRM3y5n
# P+e6mK4cD08wDgYDVR0PAQH/BAQDAgGGMBMGA1UdJQQMMAoGCCsGAQUFBwMIMHcG
# CCsGAQUFBwEBBGswaTAkBggrBgEFBQcwAYYYaHR0cDovL29jc3AuZGlnaWNlcnQu
# Y29tMEEGCCsGAQUFBzAChjVodHRwOi8vY2FjZXJ0cy5kaWdpY2VydC5jb20vRGln
# aUNlcnRUcnVzdGVkUm9vdEc0LmNydDBDBgNVHR8EPDA6MDigNqA0hjJodHRwOi8v
# Y3JsMy5kaWdpY2VydC5jb20vRGlnaUNlcnRUcnVzdGVkUm9vdEc0LmNybDAgBgNV
# HSAEGTAXMAgGBmeBDAEEAjALBglghkgBhv1sBwEwDQYJKoZIhvcNAQELBQADggIB
# ABfO+xaAHP4HPRF2cTC9vgvItTSmf83Qh8WIGjB/T8ObXAZz8OjuhUxjaaFdleMM
# 0lBryPTQM2qEJPe36zwbSI/mS83afsl3YTj+IQhQE7jU/kXjjytJgnn0hvrV6hqW
# Gd3rLAUt6vJy9lMDPjTLxLgXf9r5nWMQwr8Myb9rEVKChHyfpzee5kH0F8HABBgr
# 0UdqirZ7bowe9Vj2AIMD8liyrukZ2iA/wdG2th9y1IsA0QF8dTXqvcnTmpfeQh35
# k5zOCPmSNq1UH410ANVko43+Cdmu4y81hjajV/gxdEkMx1NKU4uHQcKfZxAvBAKq
# MVuqte69M9J6A47OvgRaPs+2ykgcGV00TYr2Lr3ty9qIijanrUR3anzEwlvzZiiy
# fTPjLbnFRsjsYg39OlV8cipDoq7+qNNjqFzeGxcytL5TTLL4ZaoBdqbhOhZ3ZRDU
# phPvSRmMThi0vw9vODRzW6AxnJll38F0cuJG7uEBYTptMSbhdhGQDpOXgpIUsWTj
# d6xpR6oaQf/DJbg3s6KCLPAlZ66RzIg9sC+NJpud/v4+7RWsWCiKi9EOLLHfMR2Z
# yJ/+xhCx9yHbxtl5TPau1j/1MIDpMPx0LckTetiSuEtQvLsNz3Qbp7wGWqbIiOWC
# nb5WqxL3/BAPvIXKUjPSxyZsq8WhbaM2tszWkPZPubdcMIIFjTCCBHWgAwIBAgIQ
# DpsYjvnQLefv21DiCEAYWjANBgkqhkiG9w0BAQwFADBlMQswCQYDVQQGEwJVUzEV
# MBMGA1UEChMMRGlnaUNlcnQgSW5jMRkwFwYDVQQLExB3d3cuZGlnaWNlcnQuY29t
# MSQwIgYDVQQDExtEaWdpQ2VydCBBc3N1cmVkIElEIFJvb3QgQ0EwHhcNMjIwODAx
# MDAwMDAwWhcNMzExMTA5MjM1OTU5WjBiMQswCQYDVQQGEwJVUzEVMBMGA1UEChMM
# RGlnaUNlcnQgSW5jMRkwFwYDVQQLExB3d3cuZGlnaWNlcnQuY29tMSEwHwYDVQQD
# ExhEaWdpQ2VydCBUcnVzdGVkIFJvb3QgRzQwggIiMA0GCSqGSIb3DQEBAQUAA4IC
# DwAwggIKAoICAQC/5pBzaN675F1KPDAiMGkz7MKnJS7JIT3yithZwuEppz1Yq3aa
# za57G4QNxDAf8xukOBbrVsaXbR2rsnnyyhHS5F/WBTxSD1Ifxp4VpX6+n6lXFllV
# cq9ok3DCsrp1mWpzMpTREEQQLt+C8weE5nQ7bXHiLQwb7iDVySAdYyktzuxeTsiT
# +CFhmzTrBcZe7FsavOvJz82sNEBfsXpm7nfISKhmV1efVFiODCu3T6cw2Vbuyntd
# 463JT17lNecxy9qTXtyOj4DatpGYQJB5w3jHtrHEtWoYOAMQjdjUN6QuBX2I9YI+
# EJFwq1WCQTLX2wRzKm6RAXwhTNS8rhsDdV14Ztk6MUSaM0C/CNdaSaTC5qmgZ92k
# J7yhTzm1EVgX9yRcRo9k98FpiHaYdj1ZXUJ2h4mXaXpI8OCiEhtmmnTK3kse5w5j
# rubU75KSOp493ADkRSWJtppEGSt+wJS00mFt6zPZxd9LBADMfRyVw4/3IbKyEbe7
# f/LVjHAsQWCqsWMYRJUadmJ+9oCw++hkpjPRiQfhvbfmQ6QYuKZ3AeEPlAwhHbJU
# KSWJbOUOUlFHdL4mrLZBdd56rF+NP8m800ERElvlEFDrMcXKchYiCd98THU/Y+wh
# X8QgUWtvsauGi0/C1kVfnSD8oR7FwI+isX4KJpn15GkvmB0t9dmpsh3lGwIDAQAB
# o4IBOjCCATYwDwYDVR0TAQH/BAUwAwEB/zAdBgNVHQ4EFgQU7NfjgtJxXWRM3y5n
# P+e6mK4cD08wHwYDVR0jBBgwFoAUReuir/SSy4IxLVGLp6chnfNtyA8wDgYDVR0P
# AQH/BAQDAgGGMHkGCCsGAQUFBwEBBG0wazAkBggrBgEFBQcwAYYYaHR0cDovL29j
# c3AuZGlnaWNlcnQuY29tMEMGCCsGAQUFBzAChjdodHRwOi8vY2FjZXJ0cy5kaWdp
# Y2VydC5jb20vRGlnaUNlcnRBc3N1cmVkSURSb290Q0EuY3J0MEUGA1UdHwQ+MDww
# OqA4oDaGNGh0dHA6Ly9jcmwzLmRpZ2ljZXJ0LmNvbS9EaWdpQ2VydEFzc3VyZWRJ
# RFJvb3RDQS5jcmwwEQYDVR0gBAowCDAGBgRVHSAAMA0GCSqGSIb3DQEBDAUAA4IB
# AQBwoL9DXFXnOF+go3QbPbYW1/e/Vwe9mqyhhyzshV6pGrsi+IcaaVQi7aSId229
# GhT0E0p6Ly23OO/0/4C5+KH38nLeJLxSA8hO0Cre+i1Wz/n096wwepqLsl7Uz9FD
# RJtDIeuWcqFItJnLnU+nBgMTdydE1Od/6Fmo8L8vC6bp8jQ87PcDx4eo0kxAGTVG
# amlUsLihVo7spNU96LHc/RzY9HdaXFSMb++hUD38dglohJ9vytsgjTVgHAIDyyCw
# rFigDkBjxZgiwbJZ9VVrzyerbHbObyMt9H5xaiNrIv8SuFQtJ37YOtnwtoeW/VvR
# XKwYw02fc7cBqZ9Xql4o4rmUMYIDfDCCA3gCAQEwfTBpMQswCQYDVQQGEwJVUzEX
# MBUGA1UEChMORGlnaUNlcnQsIEluYy4xQTA/BgNVBAMTOERpZ2lDZXJ0IFRydXN0
# ZWQgRzQgVGltZVN0YW1waW5nIFJTQTQwOTYgU0hBMjU2IDIwMjUgQ0ExAhAKgO8Y
# S43xBYLRxHanlXRoMA0GCWCGSAFlAwQCAQUAoIHRMBoGCSqGSIb3DQEJAzENBgsq
# hkiG9w0BCRABBDAcBgkqhkiG9w0BCQUxDxcNMjYwNDIxMTgzNDQ3WjArBgsqhkiG
# 9w0BCRACDDEcMBowGDAWBBTdYjCshgotMGvaOLFoeVIwB/tBfjAvBgkqhkiG9w0B
# CQQxIgQgBXUrRbWx95MytMEIW4eE/lJPeO/Gmqzq0N8Rb0pfZhkwNwYLKoZIhvcN
# AQkQAi8xKDAmMCQwIgQgSqA/oizXXITFXJOPgo5na5yuyrM/420mmqM08UYRCjMw
# DQYJKoZIhvcNAQEBBQAEggIAyG33UGvnONKpxeY2tndWaSmIHTzEKcgAeqc6fuwM
# 2TXFTiBry8M+9MfEam9oK/kOyuM7lN7iuviXRiJB33tiixIkj1MwwF0nqbrmtOyT
# c/5F8KfA7txKdw9vENAy3dh61uTFKoqTYKvgS5lz+EmDFXNZHmRdwnVtZroo8JnM
# xcMK3cDxB/muBkeDu3EZbxi1Obu7EMiunndjRuxtn/ZxLhbUrMQ0+cdS6bMZ3aBZ
# Hp4r3sPNadwEbaZJnoBR0unM69vcUJWM4EuL4YenSeCXbv1d5Dr/Ul1/849omjrN
# p0kDB0lswJPkzrctCYlaNjsIoo7rvJMow+J53nulKtxMAKIUvyjDxKOgaJMePkM+
# XtZJr/DXoOAFBqjMwayc3uESAzvZPkx7MtKseS4v9OhCA6witvmnAP3eKNNHtivd
# uncZ2R3EjQdGE0nnGca7dMAhyjk/K3aA7YnDnAEln2BPx1gBBBDAt9WUfbH994Lw
# hUgIIYMDcQ4IgpUtjI7lue1fFv0R/BMkwNWlaHPWze5AsUJQ+z3Ef2Fq4egf9/0k
# Yts90NM+9g2LFd81q29VmlUfCelymuAJnM2L+oW5/ugvEnagPVa7AkFgfM7gUyME
# er00ni+JWTGaUC6IfR9foWK20JspyF3+FfvfXUdaw49Y5WYOpxfSZDNCDzaDBzf3
# yAk=
# SIG # End signature block
