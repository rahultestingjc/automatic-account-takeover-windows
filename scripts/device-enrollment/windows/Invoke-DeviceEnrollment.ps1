# ================= EXECUTION POLICY =================
Set-ExecutionPolicy -Scope Process Bypass -Force
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

# ================= PATHS =================
$PublicDir  = "C:\Users\Public\Documents"
$LogFile    = "$PublicDir\jc_device_bind.log"
$EmailFile  = "$PublicDir\jc_email.txt"
$ResultFile = "$PublicDir\jc_result.txt"

if (!(Test-Path $PublicDir)) {
    New-Item -ItemType Directory -Path $PublicDir -Force | Out-Null
}

function Write-Log {
    param($msg)
    $time = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $line = "$time : $msg"
    $line | Out-File $LogFile -Append
    Write-Host $line
}

New-Item $LogFile -ItemType File -Force | Out-Null
Write-Log "Script started"
Write-Log "Running context: $([System.Security.Principal.WindowsIdentity]::GetCurrent().Name)"

# ================= ENSURE RunAsUser MODULE =================
try {
    if (-not (Get-Module -ListAvailable -Name RunAsUser)) {
        Write-Log "RunAsUser not found. Installing prerequisites..."

        if (-not (Get-PackageProvider -Name NuGet -ErrorAction SilentlyContinue)) {
            Install-PackageProvider -Name NuGet -MinimumVersion 2.8.5.201 -Force -Scope AllUsers | Out-Null
        }

        if (-not (Get-PSRepository -Name PSGallery -ErrorAction SilentlyContinue)) {
            Register-PSRepository -Default
        }

        if ((Get-PSRepository -Name PSGallery).InstallationPolicy -ne 'Trusted') {
            Set-PSRepository -Name PSGallery -InstallationPolicy Trusted
        }

        Install-Module -Name RunAsUser -Scope AllUsers -Force -AllowClobber -Confirm:$false -ErrorAction Stop
        Write-Log "RunAsUser installed successfully."
    }

    Import-Module RunAsUser -Force -ErrorAction Stop
}
catch {
    Write-Log "Failed to load RunAsUser module: $($_.Exception.Message)"
    exit 1
}

# ================= CONFIG =================
# NOTE: {{Apikey}} and {{device.id}} are JumpCloud MDM command template
# variables. JumpCloud substitutes the real values at runtime when the
# command is dispatched to the device. Do NOT hardcode a real API key here.
$JC_API_KEY = {{Apikey}}
# EU-region tenants: change this to https://console.eu.jumpcloud.com/api
$JC_BASE    = "https://console.jumpcloud.com/api"
$SystemID   = {{device.id}}

Write-Log "SystemID: $SystemID"

# =================================================
# EMAIL PROMPT (RunAsUser)
# =================================================
$PromptEmail = {

    Add-Type -AssemblyName Microsoft.VisualBasic
    $EmailFile = "C:\Users\Public\Documents\jc_email.txt"

    $email = [Microsoft.VisualBasic.Interaction]::InputBox(
        "Enter your JumpCloud email address:",
        "JumpCloud Device Enrollment",
        ""
    )

    if (![string]::IsNullOrWhiteSpace($email)) {
        $email.Trim().ToLower() | Out-File $EmailFile -Force
    }

}

Invoke-AsCurrentUser -ScriptBlock $PromptEmail | Out-Null

# =================================================
# SYSTEM CONTINUES
# =================================================

$BindingStatus = "Good"
$IssueReason   = "None"
$ResultMessage = ""

# =================================================
# READ EMAIL
# =================================================

if ($BindingStatus -eq "Good") {

    if (!(Test-Path $EmailFile)) {

        $BindingStatus = "RequiresAction"
        $IssueReason   = "Email not provided"
        $ResultMessage = "Device enrollment incomplete.`n`nEmail not entered."

    }
    else {

        $EmailLower = Get-Content $EmailFile
        Write-Log "Email entered: $EmailLower"

    }

}

# =================================================
# FETCH JC USER
# =================================================

if ($BindingStatus -eq "Good") {

    try {

        $UserResp = Invoke-RestMethod `
            -Method GET `
            -Uri "$JC_BASE/systemusers?filter=email:eq:$EmailLower" `
            -Headers @{
                "x-api-key" = $JC_API_KEY
                "Accept"    = "application/json"
            }

        if (!$UserResp.results) { throw }

        $UserID     = $UserResp.results[0]._id
        $JCUsername = $UserResp.results[0].username

        Write-Log "JumpCloud user_id: $UserID"
        Write-Log "JumpCloud username: $JCUsername"

    }
    catch {

        $BindingStatus = "RequiresAction"
        $IssueReason   = "JumpCloud user not found"
        $ResultMessage = "Device enrollment incomplete.`n`nUnable to find JumpCloud user."

    }

}

# =================================================
# DETECT LOCAL USER
# =================================================

if ($BindingStatus -eq "Good") {

    try {

        $LocalUser = (Get-CimInstance Win32_ComputerSystem).UserName
        $LocalUser = $LocalUser.Split('\')[-1].Trim()

        Write-Log "Local user: $LocalUser"

    }
    catch {

        $BindingStatus = "RequiresAction"
        $IssueReason   = "Unable to detect user"

    }

}

# =================================================
# DEVICE STATE DETECTION
# =================================================

$IsDomainJoined  = $false
$IsAzureADJoined = $false
$IsMSAccount     = $false

try {
    if ((Get-CimInstance Win32_ComputerSystem).PartOfDomain) {
        $IsDomainJoined = $true
    }
} catch {}

try {
    $dsreg = dsregcmd /status
    if ($dsreg -match "AzureAdJoined\s*:\s*YES") {
        $IsAzureADJoined = $true
    }
} catch {}

try {
    $acct = Get-LocalUser | Where-Object { $_.Name -eq $LocalUser }
    if ($acct -and $acct.PrincipalSource -eq "MicrosoftAccount") {
        $IsMSAccount = $true
    }
} catch {}

# =================================================
# BLOCK CONDITIONS
# =================================================

if ($BindingStatus -eq "Good") {

    if ($IsDomainJoined) {

        $BindingStatus = "RequiresAction"
        $ResultMessage = "Device enrollment incomplete.`n`nDevice is domain joined."

    }
    elseif ($IsAzureADJoined) {

        $BindingStatus = "RequiresAction"
        $ResultMessage = "Device enrollment incomplete.`n`nDevice is Azure AD joined."

    }
    elseif ($IsMSAccount) {

        $BindingStatus = "RequiresAction"
        $ResultMessage = "Device enrollment incomplete.`n`nMicrosoft account detected."

    }

}

# =================================================
# USERNAME ALIGNMENT
# =================================================

if ($BindingStatus -eq "Good") {

    $LocalLower = $LocalUser.ToLower()
    $JCLower    = $JCUsername.ToLower()

    if ($LocalLower -ne $JCLower) {

        Write-Log "Username mismatch detected"

        # ---------- CASE 1 : space in username ----------
        if ($LocalUser -match "\s") {

            Write-Log "Local username contains space -> rename"

            try {

                Rename-LocalUser -Name $LocalUser -NewName $JCUsername
                Write-Log "Rename successful"
                $LocalUser = $JCUsername

            }
            catch {

                $BindingStatus = "RequiresAction"
                $IssueReason   = "Rename failed"

            }

        }

        # ---------- CASE 2 : try systemUsername ----------
        else {

            Write-Log "Attempting systemUsername update"

            try {

                Invoke-RestMethod `
                    -Method PUT `
                    -Uri "$JC_BASE/systemusers/$UserID" `
                    -Headers @{
                        "x-api-key"    = $JC_API_KEY
                        "Content-Type" = "application/json"
                    } `
                    -Body (@{ systemUsername = $LocalUser } | ConvertTo-Json) | Out-Null

                Write-Log "systemUsername update succeeded"

            }
            catch {

                Write-Log "systemUsername update failed -> rename"

                try {

                    Rename-LocalUser -Name $LocalUser -NewName $JCUsername
                    Write-Log "Rename successful"
                    $LocalUser = $JCUsername

                }
                catch {

                    $BindingStatus = "RequiresAction"
                    $IssueReason   = "Username alignment failed"

                }

            }

        }

    }

}

# =================================================
# BIND DEVICE
# =================================================

if ($BindingStatus -eq "Good") {

    Write-Log "Binding device"

    try {

        Invoke-RestMethod `
            -Method POST `
            -Uri "$JC_BASE/v2/users/$UserID/associations" `
            -Headers @{
                "x-api-key"    = $JC_API_KEY
                "Content-Type" = "application/json"
            } `
            -Body (@{
                op   = "add"
                type = "system"
                id   = $SystemID
            } | ConvertTo-Json) | Out-Null

        Write-Log "Device binding succeeded"

    }
    catch {

        $BindingStatus = "RequiresAction"
        $IssueReason   = "Binding failed"
        $ResultMessage = "Device enrollment incomplete.`n`nBinding failed."

    }

}

# =================================================
# SET PRIMARY USER
# =================================================

if ($BindingStatus -eq "Good") {

    Write-Log "Setting primary user: $UserID"

    try {

        Invoke-RestMethod `
            -Method PUT `
            -Uri "$JC_BASE/systems/$SystemID" `
            -Headers @{
                "x-api-key"    = $JC_API_KEY
                "Content-Type" = "application/json"
            } `
            -Body (@{
                primarySystemUser = @{ id = $UserID }
            } | ConvertTo-Json) | Out-Null

        Write-Log "Primary user set succeeded"
        $ResultMessage = "Device enrollment completed successfully.`n`nPlease log out and log back in."

    }
    catch {

        $BindingStatus = "RequiresAction"
        $IssueReason   = "Set primary user failed"
        $ResultMessage = "Device enrollment incomplete.`n`nFailed to set primary user."

    }

}

# =================================================
# UPDATE DEVICE DESCRIPTION IF FAILURE
# =================================================

if ($BindingStatus -ne "Good") {

    $DescText = @(
        "BindingStatus: $BindingStatus"
        "Issue: $IssueReason"
        "DomainJoined: $IsDomainJoined"
        "AzureADJoined: $IsAzureADJoined"
        "MicrosoftAccount: $IsMSAccount"
        "LocalUser: $LocalUser"
        "JCUser: $JCUsername"
        "Email: $EmailLower"
    ) -join " | "

    try {

        Invoke-RestMethod `
            -Method PUT `
            -Uri "$JC_BASE/systems/$SystemID" `
            -Headers @{
                "x-api-key"    = $JC_API_KEY
                "Content-Type" = "application/json"
            } `
            -Body (@{ description = $DescText } | ConvertTo-Json) | Out-Null

    }
    catch {

        Write-Log "Failed to update device description"

    }

}

# =================================================
# MDM OUTPUT SUMMARY (visible in MDM command output)
# =================================================

Write-Host "Status: $BindingStatus | Issue: $IssueReason | User: $EmailLower | LocalUser: $LocalUser | JCUser: $JCUsername | SystemID: $SystemID"

# =================================================
# SAVE RESULT
# =================================================

$ResultMessage | Out-File $ResultFile -Force

# =================================================
# SHOW RESULT
# =================================================

$ShowPrompt = {

    Add-Type -AssemblyName System.Windows.Forms
    $Message = Get-Content "C:\Users\Public\Documents\jc_result.txt" -Raw

    [System.Windows.Forms.MessageBox]::Show(
        $Message,
        "JumpCloud Device Enrollment"
    )

}

Invoke-AsCurrentUser -ScriptBlock $ShowPrompt | Out-Null
