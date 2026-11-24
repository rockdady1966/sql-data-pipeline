$BaseFolder = "C:\tempraholim\DB report"
$envFile = "$BaseFolder\db_instances.txt"
$dtTm = Get-Date -Format "yyyyMMddHHmmss"
$transcriptFile = "$BaseFolder\logging\db_instance_force_agency_query_transcript_$dtTm.txt"
$outputFile = "$BaseFolder\db_instance_force_agency_query_results_$dtTm.csv"
$connString = $null

$sqlQuery = "
USE DPAS;

SELECT @@SERVERNAME AS ServerName,
       f.name,
       a.agy_cd,
       a.agy_nm
FROM fsm.force AS f
INNER JOIN fsm.force_command AS fc
    ON f.force_ky = fc.force_ky
INNER JOIN fsm.force_group AS fg
    ON fc.force_command_ky = fg.force_command_ky
INNER JOIN fsm.force_element AS fe
    ON fg.force_group_ky = fe.force_group_ky
INNER JOIN dbo.agency AS a
    ON fe.agy_ky = a.agy_ky
GROUP BY f.name,
         a.agy_cd,
         a.agy_nm;
"

# Main Logging function
function Log([string]$text, [switch]$error)
{
    if($error)
    {
        Write-Error "$(Get-Date) $($text)"
    }
    else
    {
        Write-Host "$(Get-Date) $($text)"
    }

    $script:globalLog += "$(Get-Date) $($text)"
}

function OpenDBConnection([switch]$addInfoMessage, [string]$logFile)
{
    $SqlConnection = New-Object System.Data.SqlClient.SqlConnection
    $SqlConnection.ConnectionString = $connString

    if($addInfoMessage)
    {
        if(![string]::IsNullOrWhiteSpace($logFile))
        {
            $handler = [System.Data.SqlClient.SqlInfoMessageEventHandler] {
                param($sender, $event)
                $event.Message | Out-File $logFile -Append
            }
        }
        else
        {
            $handler = [System.Data.SqlClient.SqlInfoMessageEventHandler] {
                param($sender, $event)
                Log "$($event.Message)"
            }
        }

        $SqlConnection.add_InfoMessage($handler)
        $SqlConnection.FireInfoMessageEventOnUserErrors = $true
    }

    $SqlConnection.Open()

    return $SqlConnection
}

function GetDataSet([string]$sqlQuery)
{
    $SqlConnection = $null

    try
    {
        $SqlConnection = OpenDBConnection

        $SqlCmd = New-Object System.Data.SqlClient.SqlCommand
        $SqlCmd.CommandText = $sqlQuery
        $SqlCmd.Connection = $SqlConnection
        $SqlCmd.CommandTimeout = 300

        $adapter = New-Object System.Data.SqlClient.SqlDataAdapter $SqlCmd
        $dataSet = New-Object System.Data.DataSet
        $adapter.Fill($dataSet) | Out-Null

        return $dataSet
    }
    catch
    {
        $ErrorMessage = $_.Exception.Message
        Log "$ErrorMessage" -error
        throw $_.Exception
    }
    finally
    {
        CloseDBConnection -SqlConnection $SqlConnection
    }
}

function CloseDBConnection($SqlConnection)
{
    if($SqlConnection -ne $null)
    {
        $SqlConnection.Close()
    }
}

# Opens a connection to the database, if it doesn't work,
# the rest of the script is not going to work either
function CheckDBConnectivity()
{
    $SqlConnection = $null

    try
    {
        $SqlConnection = OpenDBConnection
        return $true
    }
    catch
    {
        $ErrorMessage = $_.Exception.Message
        Log "ERROR: Cannot connect to database with connection string $connString. $ErrorMessage" -error

        return $false
    }
    finally
    {
        CloseDBConnection $SqlConnection
    }
}

function WriteResultsToFile($server)
{
    try
    {
        $dataSet = GetDataSet -SqlQuery $sqlQuery
    }
    catch
    {
        $ErrorMessage = $_.Exception.Message
        Add-Content $outputFile "$server,ALL,'Error receiving results. $ErrorMessage',,,,,,,,,,,,,,,,"
    }

    foreach($t in $dataSet.Tables)
    {
        $t | Export-Csv $outputFile -NoTypeInformation -Append
    }

    <#
    if($dataSet.Tables[0].rows.Count -eq 0)
    {
        #Add-Content $outputFile "$server,ALL,'No results returned.',,,,,,,,,,,,,,,,"
    }
    else
    {
        $dataSet.Tables[0] | Export-Csv $outputFile -NoTypeInformation -Append
    }
    #>
}

Start-Transcript -Path $transcriptFile

# If any old reports still exist, remove it.
Remove-Item $BaseFolder\db_instance_query_results*

foreach($server in Get-Content $envFile)
{
    Write-Output "$server"

    $script:connString = "Data Source=$server;Integrated Security=True;Pooling=False"

    $dbConnected = CheckDBConnectivity

    if($dbConnected -eq $false)
    {
        Write-Error "Cannot connect to $server"
    }
    else
    {
        WriteResultsToFile -server $server
    }
}

<# 
Send-MailMessage `
    -From "No-Reply <noreply@leidos.com>" `
    -To "marc.raholin@leidos.com" `
    -Subject "Baseline DB File Report - $($env:computername)" `
    -Body "Attached is the Baseline DB File Report for our internal environments." `
    -Attachments $outputFile `
    -SmtpServer smtp.leidos.com
#>

Stop-Transcript