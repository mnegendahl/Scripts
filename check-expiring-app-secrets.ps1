<#
.SYNOPSIS
    Checks Entra ID (Azure AD) application secrets for upcoming expiration.

.DESCRIPTION
    This script connects to Microsoft Graph using a service principal and identifies app secrets 
    that are expiring within 30 days. It then sends an HTML email report via SendGrid if any are found.

.PREREQUISITES
    - A service principal with **Application.Read.All** permissions in Microsoft Graph (admin consented).
    - This service principal must be added as a credential asset in Azure Automation.
    - SendGrid SMTP credentials must also be added as an Azure Automation credential asset.
    - Update placeholder values like email addresses, tenant ID, and logo URL to match your environment.

.EXAMPLE
    This script can be scheduled to run regularly as an Azure Automation runbook to alert about expiring secrets.
#>

# Initialize variables
$GraphCreds = Get-AutomationPSCredential -Name 'GraphAppSecretMonitor'
$MailCreds  = Get-AutomationPSCredential -Name 'sendgrid-credential'
$tenantId   = '<YOUR_TENANT_ID>'

$AppsWithExpiringSecrets = @()
$DateThreshold = (Get-Date).AddDays(30)

$SMTPServer = 'smtp.sendgrid.com'
$MailFrom   = 'noreply@example.com'
$MailTo     = 'recipient@example.com'
$MailSubject = 'Entra ID app secret about to expire - Alert'

# Connect to Microsoft Graph
Connect-MgGraph -Credential $GraphCreds -TenantId $tenantId

try {
    $AllApps = Get-MgApplication -All
} catch {
    throw "Failed to retrieve applications from Microsoft Graph: $_"
}

foreach ($app in $AllApps) {
    foreach ($AppPassCred in $app.PasswordCredentials) {
        if ($AppPassCred.EndDateTime -le $DateThreshold) {
            $AppsDetails = [PSCustomObject]@{
                'App ID'                = $app.AppId
                'App DisplayName'       = $app.DisplayName
                'Secret Description'    = $AppPassCred.DisplayName
                'Secret Expiration Date'= $AppPassCred.EndDateTime
            }
            $AppsWithExpiringSecrets += $AppsDetails
        }
    }
}

if ($AppsWithExpiringSecrets.Count -ne 0) {
    $TableHtml = ($AppsWithExpiringSecrets | ConvertTo-Html -Title 'Detected secrets' | Out-String)

    $MailBody = @"
<!DOCTYPE html>
<html>
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <style>
        body { margin: 0; padding: 0; background-color: #f4f4f4; font-family: Arial, sans-serif; }
        table { border-spacing: 0; width: 100%; max-width: 800px; margin: 0 auto; background-color: #ffffff; }
        td { padding: 0; }
        tr { text-align: left; }
        .header { background-color: #f4f4f4; color: #050505; padding: 20px; text-align: right; }
        .header img { height: 50px; vertical-align: middle; }
        .header h1 { display: inline; font-size: 24px; margin-left: 10px; vertical-align: middle; }
        .content { padding: 20px; }
        .content p { margin: 16px 0; }
        .footer { background-color: #f4f4f4; color: #888888; text-align: center; padding: 10px; font-size: 12px; }
        table, th, td { border: 1px solid #ccc; border-collapse: collapse; }
        th, td { padding: 8px; }
    </style>
</head>
<body>
    <table>
        <tr>
            <td class="header">
                <img src="https://yourdomain.com/logo.png" height="50" align="left">
                <h1>Automation Notification</h1>
            </td>
        </tr>
        <tr>
            <td class="content">
                <p>Hi,</p>
                <p>This is an automated report showing Entra ID app secrets that are expiring within 30 days or already expired.</p>
                $TableHtml
            </td>
        </tr>
        <tr>
            <td class="footer">
                <p>IT Automation</p>
            </td>
        </tr>
    </table>
</body>
</html>
"@

    try {
        Send-MailMessage -To $MailTo -Subject $MailSubject -Body $MailBody `
            -SmtpServer $SMTPServer -From $MailFrom -BodyAsHtml -Port 587 -Credential $MailCreds
    } catch {
        throw "Failed to send email: $_"
    }
} else {
    Write-Output "No apps with expiring secrets found."
}

Disconnect-MgGraph
