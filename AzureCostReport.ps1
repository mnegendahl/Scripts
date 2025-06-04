# Debug mode for different email recipient
$debug = $false

# For Azure cost access (Managed Identity or SPN with Reader)
$azcreds = Get-AutomationPSCredential -Name 'AzureCostReportSP'
$TenantId = '<YOUR_TENANT_ID>'
Connect-AzAccount -ServicePrincipal -Credential $azcreds -TenantId $TenantId

# Define date range for this month
$today = Get-Date
$thisMonthStart = (Get-Date -Day 1).ToString("yyyy-MM-dd")
$thisMonthEnd = $today.ToString("yyyy-MM-dd")

# For sending email via SendGrid
$mailcreds = Get-AutomationPSCredential -Name 'sendgrid-credential'
$SMTPServer = "smtp.sendgrid.com"
$EmailFrom = "noreply@example.com"
$EmailTo = if ($debug) { "debug@example.com" } else { "recipient1@example.com","recipient2@example.com" }
$emailsubject = "Monthly Azure Cost Report - $thisMonthStart to $thisMonthEnd"

# Get all subscriptions
$subscriptions = Get-AzSubscription | Where-Object { $_.State -eq 'Enabled' }
$results = @()

foreach ($sub in $subscriptions) {
    try {
        Set-AzContext -SubscriptionId $sub.Id -ErrorAction Stop

        $actualBody = @{
            type = "ActualCost"
            timeframe = "Custom"
            timePeriod = @{
                from = $thisMonthStart
                to   = $thisMonthEnd
            }
            dataset = @{
                aggregation = @{
                    totalCost = @{
                        name = "PreTaxCost"
                        function = "Sum"
                    }
                }
            }
        } | ConvertTo-Json -Depth 10

        $actualResp = Invoke-AzRestMethod -Method POST `
            -Path "/subscriptions/$($sub.Id)/providers/Microsoft.CostManagement/query?api-version=2023-03-01" `
            -Payload $actualBody

        $actualRows = ($actualResp.Content | ConvertFrom-Json).properties.rows
        $actualCost = if ($actualRows -and $actualRows.Count -gt 0) { '{0:N2}' -f $actualRows[0][0] } else { "N/A" }

        $results += [PSCustomObject]@{
            SubscriptionName = $sub.Name
            SubscriptionId   = $sub.Id
            ActualCostDKK    = $actualCost
        }
    }
    catch {
        Write-Warning "Skipping $($sub.Name): $($_.Exception.Message)"
    }
}

# Sort by cost descending
$valid = $results | Where-Object { $_.ActualCostDKK -ne "N/A" }
$valid = $valid | Sort-Object {[decimal]($_.ActualCostDKK -replace ',', '')} -Descending
$invalid = $results | Where-Object { $_.ActualCostDKK -eq "N/A" }
$results = $valid + $invalid

# Generate HTML table
if ($results.Count -eq 0) {
    $overcommitTable = "<p>No cost data available for any subscription.</p>"
} else {
    $tableRows = @()
    foreach ($entry in $results) {
        $tableRows += "<tr><td>$($entry.SubscriptionName)</td><td>$($entry.SubscriptionId)</td><td>$($entry.ActualCostDKK) DKK</td></tr>"
    }

    $tableBody = $tableRows -join "`n"

    $overcommitTable = "<table>
        <tr>
            <th>Subscription Name</th>
            <th>Subscription ID</th>
            <th>Actual Cost (DKK)</th>
        </tr>
        $tableBody
    </table>"
}

# Email body using HTML template
$emailbody = @"
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
                <p>This is an automated report showing Azure cost across all subscriptions for this month ($thisMonthStart to $thisMonthEnd).</p>
                $overcommitTable
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

# Send email via SendGrid
Send-MailMessage -To $EmailTo `
    -From $EmailFrom `
    -Subject $emailsubject `
    -Body $emailbody `
    -BodyAsHtml `
    -SmtpServer $SMTPServer `
    -Credential $mailcreds `
    -Port 587
