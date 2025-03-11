<#
    Title:          Azure Sentinel Log Ingestion - Process Log Queue Messages
    Language:       PowerShell
    Version:        1.3.0
    Author(s):      Sreedhar Ande, MF@CF
    Last Modified:  2025-03-09
    Comment:        Rebased Build
    DESCRIPTION
    This function monitors an Azure Storage queue for messages then retrieves the file and preps it for Ingestion processing.
    CHANGE HISTORY
    1.0.0 Inital release of code
    1.3.0 Submits blob content not queue message
#>
# Input bindings are passed in via param block.
param( [object]$QueueItem, [object]$TriggerMetadata )
# $VerbosePreference = "Continue"
# Write out the queue message and metadata to the information log.
#####Environment Variables
$AzureWebJobsStorage = $env:AzureWebJobsStorage
$WorkspaceId = $env:WorkspaceId
$Workspacekey = $env:LogAnalyticsWorkspaceKey
$LATableName = $env:LATableName
$LAURI = $env:LAURI
$AzureQueueName = $env:StgQueueName
#####Build the JSON from queue and grab blob path vars
# $StorageAccountName = $QueueArr.topic.split('/')[-1]
# $ResourceGroup      = $QueueArr.topic.split('/')[4]
$QueueID = $TriggerMetadata.Id
$QueuePOP = $TriggerMetadata.PopReceipt
$AzureStorage = New-AzStorageContext -ConnectionString $AzureWebJobsStorage
$QueueMsg = ConvertTo-Json $QueueItem -Depth 20
$QueueArr = @(ConvertFrom-Json $QueueMsg);
$ContainerName = $QueueArr.subject.split('/')[4]
$BlobPath = $QueueArr.subject.split('/')[6..($QueueArr.subject.split('/').Length - 1)] -join '/'
$evtTime = $QueueArr.eventTime
$BlobName = $QueueArr.subject.split('/')[-1]
$logPath = [System.IO.Path]::Combine($env:TEMP, $BlobName)
$skipNonLog = $false;
$skipfile = $false;
#check that fn host env vars' workspace ID is valid and that we're sending to LA HTTP REST
if($LAURI.Trim() -notmatch 'https:\/\/([\w\-]+)\.ods\.opinsights\.azure.([a-zA-Z\.]+)$')
{
    Write-Error -Message "Storage Account Blobs Ingestion: Invalid Log Analytics Uri." -ErrorAction Stop
	Exit
}
# useful if log source does not provide explicit json, only a csv of property values to reconstruct
# Function Convert-LogLineToJson([String] $logLine) {
#     #supporting Functions
#
#     Function Convert-SemicolonToURLEncoding([String] $InputText) {
#         $ReturnText = ""
#         $chars = $InputText.ToCharArray()
#         $StartConvert = $false
#         foreach ($c in $chars) {
#             if ($c -eq '"') {
#                 $StartConvert = ! $StartConvert
#             }
#             if ($StartConvert -eq $true -and $c -eq ';') {
#                 $ReturnText += "%3B"
#             }
#             else {
#                 $ReturnText += $c
#             }
#         }
#         return $ReturnText
#     }
#     Function ConvertTo-JsonValue($Text) {
#         $Text1 = ""
#         if ($Text.IndexOf("`"") -eq 0) { $Text1 = $Text } else { $Text1 = "`"" + $Text + "`"" }
#         if ($Text1.IndexOf("%3B") -ge 0) {
#             $ReturnText = $Text1.Replace("%3B", ";")
#         }
#         else {
#             $ReturnText = $Text1
#         }
#         return $ReturnText
#     }
#     #Convert semicolon to %3B in the log line to avoid wrong split with ";"
#     $logLineEncoded = Convert-SemicolonToURLEncoding($logLine)
#     $elements = $logLineEncoded.split(';')
#     $FormattedElements = New-Object System.Collections.ArrayList
#     foreach ($element in $elements) {
#         # Validate if the text starts with ", and add it if not
#         $NewText = ConvertTo-JsonValue($element)
#         # Use "> null" to avoid annoying index print in the console
#         $FormattedElements.Add($NewText) |out-null
#     }
#     $Columns = ("col1", "col2")
#     # Propose json payload
#     $logJson = "[{";
#     For ($i = 0; $i -lt $Columns.Length; $i++) {
#         $logJson += "`"" + $Columns[$i] + "`":" + $FormattedElements[$i]
#         if ($i -lt $Columns.Length - 1) {
#             $logJson += ","
#         }
#     }
#     $logJson += "}]";
#     return $logJson
# }
Function Write-OMSLogfile {
    <#
    .SYNOPSIS
    Inputs a hashtable, date and workspace type and writes it to a Log Analytics Workspace.
    .DESCRIPTION
    Given a  value pair hash table, this function will write the data to an OMS Log Analytics workspace.
    Certain variables, such as Customer ID and Shared Key are specific to the OMS workspace data is being written to.
    This function will not write to multiple OMS workspaces.  Build-Signature and post-analytics function from Microsoft documentation
    at https://docs.microsoft.com/azure/log-analytics/log-analytics-data-collector-api
    .PARAMETER DateTime
    date and time for the log.  DateTime value
    .PARAMETER Type
    Name of the logfile or Log Analytics "Type".  Log Analytics will append _CL at the end of custom logs  String Value
    .PARAMETER LogData
    A series of key, value pairs that will be written to the log.  Log file are unstructured but the key should be consistent
    withing each source.
    .INPUTS
    The parameters of data and time, type and logdata.  Logdata is converted to JSON to submit to Log Analytics.
    .OUTPUTS
    The Function will return the HTTP status code from the Post method.  Status code 200 indicates the request was received.
    .NOTES
    Version:        2.0
    Author:         Travis Roberts
    Creation Date:  7/9/2018
    Purpose/Change: Crating a stand alone function
    #>
    [cmdletbinding()]
    Param(
        [Parameter(Mandatory = $true, Position = 0)]
        [datetime]$dateTime,
        [parameter(Mandatory = $true, Position = 1)]
        [string]$type,
        [Parameter(Mandatory = $true, Position = 2)]
        [psobject]$logdata,
        [Parameter(Mandatory = $true, Position = 3)]
        [string]$CustomerID,
        [Parameter(Mandatory = $true, Position = 4)]
        [string]$SharedKey
    )
    # Supporting Functions
    # Function to create the auth signature
    Function Build-Signature ($customerId, $sharedKey, $date, $contentLength, $method, $contentType, $resource) {
        $xHeaders = "x-ms-date:" + $date
        $stringToHash = $method + "`n" + $contentLength + "`n" + $contentType + "`n" + $xHeaders + "`n" + $resource
        $bytesToHash = [Text.Encoding]::UTF8.GetBytes($stringToHash)
        $keyBytes = [Convert]::FromBase64String($sharedKey)
        $sha256 = New-Object System.Security.Cryptography.HMACSHA256
        $sha256.Key = $keyBytes
        $calculatedHash = $sha256.ComputeHash($bytesToHash)
        $encodedHash = [Convert]::ToBase64String($calculatedHash)
        $authorization = 'SharedKey {0}:{1}' -f $customerId, $encodedHash
        return $authorization
    }
    # Function to create and post the request
    Function Submit-OMSPostReq ($CustomerID, $SharedKey, $Body, $Type) {
        $method = "POST"
        $ContentType = 'application/json'
        $resource = '/api/logs'
        $rfc1123date = (Get-Date).ToString('r')
        $utcEvtTime = $datetime.ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ")
        $ContentLength = $Body.Length
        $signature = Build-Signature `
            -customerId $CustomerID `
            -sharedKey $SharedKey `
            -date $rfc1123date `
            -contentLength $ContentLength `
            -method $method `
            -contentType $ContentType `
            -resource $resource
		$uri = $LAURI.Trim() + $resource + "?api-version=2016-04-01"
        $headers = @{
            "Authorization"        = $signature;
            "Log-Type"             = $type;
            "x-ms-date"            = $rfc1123date;
            "time-generated-field" = $utcEvtTime;
        }
        $response = Invoke-WebRequest -Uri $uri -Method $method -ContentType $ContentType -Headers $headers -Body $Body -UseBasicParsing -Verbose
        Write-Verbose -Message ('Post Function Return Code ' + $response.statuscode)
        return $response.statuscode
    }
    #Build the JSON file
    # $logMessage = ($logdata | ConvertTo-Json -Depth 20)
    Write-Verbose -Message ("Log Message POST Body:`n" + $logMessage)
    #Submit the data
    $returnCode = Submit-OMSPostReq -CustomerID $CustomerID -SharedKey $SharedKey -Body $logdata -Type $type -Verbose
    Write-Verbose -Message ("Post Statement Return Code " + $returnCode)
    return $returnCode
}
Function Submit-ChunkLAdata ($corejson, $customLogName) {
    #Test Size; Log A limit is 30MB
    $tempdata = @()
    $tempDataSize = 0
    if ((($corejson |  ConvertTo-Json -depth 20).Length) -gt 25MB) {
		Write-Warning -Message ("Upload is over 25MB, needs to be split")
        foreach ($record in $corejson) {
            $tempdata += $record
            $tempDataSize += ($record | ConvertTo-Json -depth 20).Length
            if ($tempDataSize -gt 25MB) {
                Write-OMSLogfile -dateTime $evtTime -type $customLogName -logdata $tempdata -CustomerID $workspaceId -SharedKey $workspaceKey -Verbose
                write-Host "Sending dataset = $TempDataSize"
                $tempdata = $null
                $tempdata = @()
                $tempDataSize = 0
            }
        }
        Write-Host "Sending left over data = $Tempdatasize"
        Write-OMSLogfile -dateTime $evtTime -type $customLogName -logdata $corejson -CustomerID $workspaceId -SharedKey $workspaceKey -Verbose
    }
    Else {
        #Send to Log A as is
        Write-OMSLogfile -dateTime $evtTime -type $customLogName -logdata $corejson -CustomerID $workspaceId -SharedKey $workspaceKey -Verbose
    }
}
function Rename-JsonProperties {
    param ([string]$rawJson )
    # Convert the raw JSON primitive to a PowerShell object
    $modJson = $rawJson | ConvertFrom-Json
    $modJson | Add-Member -MemberType NoteProperty -Name "TimeGenerated" -Value $modJson."@timestamp" -Force
    # TODO: param-ize custom prop name list
    [hashtable]$logToTablePropNames = [ordered]@{
        "_id"                       = "F5_id_CF";
        "_visitor_id"               = "F5_visitor_id_CF";
        "@timestamp"                = "F5_timestamp_CF";
        "action"                    = "action_CF";
        "api_endpoint"              = "api_endpoint_CF";
        "app_firewall_name"         = "app_firewall_name_CF"; # Added property
        "app_type"                  = "app_type_CF";
        "app"                       = "app_CF";
        "as_number"                 = "as_number_CF";
        "as_org"                    = "as_org_CF";
        "asn"                       = "asn_CF";
        "attack_types"              = "attack_types_CF";
        "authority"                 = "authority_CF";
        "bot_info"                  = "bot_info_CF";
        "browser_type"              = "browser_type_CF";
        "calculated_action"         = "calculated_action_CF";
        "city"                      = "city_CF";
        "cluster_name"              = "cluster_name_CF";
        "country"                   = "country_CF";
        "dcid"                      = "dcid_CF";
        "detections"                = "detections_CF";
        "device_type"               = "device_type_CF";
        "domain"                    = "domain_CF";
        "dst_instance"              = "dst_instance_CF";
        "dst_ip"                    = "dst_ip_CF";
        "dst_port"                  = "dst_port_CF";
        "dst_site"                  = "dst_site_CF";
        "dst"                       = "dst_CF";
        "enforcement_mode"          = "enforcement_mode_CF"; # Added property
        "excluded_threat_campaigns" = "excluded_threat_campaigns_CF";
        "hostname"                  = "hostname_CF";
        "http_version"              = "http_version_CF";
        "is_new_dcid"               = "is_new_dcid_CF";
        "is_truncated_field"        = "is_truncated_field_CF";
        "kubernetes"                = "kubernetes_CF";
        "latitude"                  = "latitude_CF";
        "longitude"                 = "longitude_CF";
        "messageid"                 = "messageid_CF";
        "method"                    = "method_CF";
        "namespace"                 = "namespace_CF";
        "network"                   = "network_CF";
        "no_active_detections"      = "no_active_detections_CF";
        "original_headers"          = "original_headers_CF";
        "original_path"             = "original_path_CF";
        "path"                      = "path_CF";
        "region"                    = "region_CF";
        "req_headers_size"          = "req_headers_size_CF";
        "req_headers"               = "req_headers_CF";
        "req_id"                    = "req_id_CF";
        "req_params"                = "req_params_CF";
        "req_path"                  = "req_path_CF";
        "req_size"                  = "req_size_CF";
        "rsp_code_class"            = "rsp_code_class_CF";
        "rsp_code"                  = "rsp_code_CF";
        "rsp_size"                  = "rsp_size_CF";
        "sec_event_name"            = "sec_event_name_CF";
        "sec_event_type"            = "sec_event_type_CF";
        "severity"                  = "severity_CF";
        "signatures"                = "signatures_CF";
        "site"                      = "site_CF";
        "sni"                       = "sni_CF";
        "src_instance"              = "src_instance_CF";
        "src_ip"                    = "src_ip_CF";
        "src_port"                  = "src_port_CF";
        "src_site"                  = "src_site_CF";
        "src"                       = "src_CF";
        "stream"                    = "stream_CF";
        "tag"                       = "tag_CF";
        "tenant"                    = "tenant_CF";
        "threat_campaigns"          = "threat_campaigns_CF";
        "time"                      = "time_CF";
        "tls_fingerprint"           = "tls_fingerprint_CF";
        "user_agent"                = "user_agent_CF";
        "user"                      = "user_CF";
        "vh_name"                   = "vh_name_CF";
        "vhost_id"                  = "vhost_id_CF";
        "violation_details"         = "violation_details_CF";
        "violation_rating"          = "violation_rating_CF";
        "violations"                = "violations_CF";
        "waf_mode"                  = "waf_mode_CF";
        "x_forwarded_for"           = "x_forwarded_for_CF";
       #"TimeGenerated"             = "TimeGenerated";
    }
    # Rename the properties
    foreach ($jsonProp in $modJson) {
        foreach ($oldName in $logToTablePropNames.Keys) {
            if ($jsonProp | Select-Object -ExpandProperty $oldName.Trim() -ErrorAction SilentlyContinue) {
                $jsonProp | Add-Member -MemberType NoteProperty `
                    -Name $logToTablePropNames[$oldName] -Value ($jsonProp | Select-Object -ExpandProperty $oldName)
                $jsonProp.PSObject.Properties.Remove($oldName)
            }
        }
    }
    # Convert the updated data back to JSON
    $updatedJson = $modJson | ConvertTo-Json -Depth 20
    return $updatedJson
}

##### Execution
Write-Host ("######################################################################################")
Write-Host ("######################### BEGIN NEW TRANSACTION ######################################")
Write-Host ("################# $BlobName ################")
Write-Host ("######################################################################################")
Write-Host ("Dequeue count               :" + $TriggerMetadata.DequeueCount)
Write-Host ("PowerShell queue trigger function processed work item:" + $QueueItem)
Write-Host ("Log Analytics URI           :" + $LAURI)
Write-Host ("Queue Message ID            :" + $QueueId)
Write-Host ("Queue Message Pop receipt   :" + $QueuePOP)
Write-Host ("Current Directory           :" + $(Get-Location))
Write-Host ("Queue item expiration time  :" + $TriggerMetadata.ExpirationTime)
Write-Host ("Queue item insertion time   :" + $TriggerMetadata.InsertionTime)
Write-Host ("Queue item next visible time:" + $TriggerMetadata.NextVisibleTime)
Write-Host ("$evtTime Queue Reported new item - BlobName:  $BlobName")

# Skip processing of non-relevant files that got written to the storage container
if ($BlobName -notlike "*.log") {
    Write-Verbose "Ignoring ConcurrencyStatus.json/non-Log file"
    $skipfile = 1;
    $skipNonLog = 1;
}

# LogFile Collection and check/skip empty
if ($skipNonLog -ne 1){
    try {
        Write-Output "Attempting to download blob content..."
        Get-AzStorageBlobContent -Context $AzureStorage -Container $ContainerName -Blob $BlobPath -Destination $logPath -Force |out-null
        Write-Output "Blob content downloaded to $logPath"
    }
    catch {
        Write-Output "Error downloading blob content: $_"
    }
    $logsFromFile = Get-Content -Path $logPath -Raw
    if ($logsFromFile.length -eq 0 -or $null -eq $logsFromFile) {
        Write-Verbose "Ignoring empty logfile";
        $skipfile = 1;
    }
}

if ($skipfile -ne 1 -and $skipNonLog -ne 1) {
    $encodedJson = [System.Text.Encoding]::UTF8.GetString([System.Text.Encoding]::UTF8.GetBytes($logsFromFile))
    $renamedJsonPrimative = Rename-JsonProperties -rawJson $encodedJson -verbose
    # If log source does not contain table headers
    # $json = Convert-LogLineToJson($log)
    # Wrapper for write-omslogfile to chunk based on REST API limit spec. Max 30Mb, this cuts at 25.
    $LAPostResult = Submit-ChunkLAdata -Verbose -Corejson $renamedJsonPrimative -CustomLogName $LATableName -verbose
}

if($LAPostResult -eq 200 -or $skipfile -eq 1) {
    Remove-Item $logPath
    Write-Output ("Storage Account Blobs ingested into Azure Log Analytics Workspace Table $LATableName")
    # Connect to Storage Queue to remove message on successful log processing
    $AzureQueue = Get-AzStorageQueue -Context $AzureStorage -Name $AzureQueueName -verbose
    Write-Output ("Dequeuing Trigger ID/popReceipt: '$QueueId :: $QueuePop' From CloudQueue '$AzureQueue'")
    $CloudQueue = $AzureQueue.CloudQueue
    Write-Verbose -Message ("Cloud Queue Reference '$CloudQueue' CloudQueue URI '$'${CloudQueue.uri}")
    # if ($null -ne $CloudQueue -and $null -ne $QueueId -and $null -ne $QueuePOP) {
        # try {
            $CloudQueue.DeleteMessage($QueueID, $QueuePOP)
        # }
        # catch {
            # Write-Warning -Message "Unable to DeQueue Item from: Queue='$CloudQueue' TriggerMetadata ID : '$queueid' QPOP: '$queuepop'"
        # }
    # } else {
        # Write-Warning -Message "Unable to DeQueue Item from: Queue='$CloudQueue' TriggerMetadata ID : '$queueid' QPOP: '$queuepop'"
    # }
    Remove-AzStorageBlob -Context $AzureStorage -Container $ContainerName -Blob $BlobPath -verbose
    [System.GC]::collect() #cleanup memory
}

Write-Host ("######################################################################################")
Write-Host ("############################ END TRANSACTION #########################################")
Write-Host ("################# $BlobName ################")
Write-Host ("######################################################################################")
[System.GC]::GetTotalMemory($true) | out-null #Force full garbage collection - Powershell does not clean itself up properly in some situations
#end of Script