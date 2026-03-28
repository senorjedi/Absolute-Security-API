
$LogFile = "$PSScriptRoot\UnenrollDevice.log"
Add-Content $LogFile ("-" * 120)
Add-Content $LogFile ("Script running from: $PSScriptRoot")
Function Now { Return (Get-Date -Format G) }

function authenticate {
    param (
        [Parameter(Mandatory)][string]$Method,
        [Parameter(Mandatory)][string]$Uri,
        [Parameter(Mandatory)]$Payload,
        [string]$QueryString
    )

    #Token for authenticating
    $TokenId =
    $SecretKey =

    #variables that is needed
    $Algorithm = "HS256"
    $ContentType = "application/json"
    $apiMethod = "POST"
    $RequestUrl = "https://api.absolute.com/jws/validate"

    #This is to grab the time
    $issat = [long][double]::parse((Get-Date -Date $((Get-Date).addseconds($ValidforSeconds).ToUniversalTime()) -UFormat %s)) * 1000

    #payload and header to be authenticated for JWT
    try {
        Add-Content -Path $LogFile -Value "$(Now) - Starting to format the payload and header to be authenticated for JWT"

        [hashtable]$header = @{alg = $Algorithm; kid = $TokenId; method = $Method; 'content-type' = $ContentType; uri = $Uri; 'query-string' = $QueryString; issuedAt = $issat }
        $headerjson = $header | ConvertTo-Json -Compress
        $payloadjson = $Payload | ConvertTo-Json -Compress | % { [regex]::Unescape($_) }

        $headerjsonbase64 = [Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes($headerjson)).Split('=')[0].Replace('+', '-').Replace('/', '_')
        $payloadjsonbase64 = [Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes($payloadjson)).Split('=')[0].Replace('+', '-').Replace('/', '_')
    }
    catch {
        Add-Content -Path $LogFile -Value "$(Now) - Header or payload failed"
        Exit 1
    }

    #This is to sign to authenticate the secret token
    try {
        Add-Content -Path $LogFile -Value "$(Now) - Successfully formatted the header and payload"
        Add-Content -Path $LogFile -Value "$(Now) - Starting to sign to authenticate the secret token"

        $ToBeSigned = $headerjsonbase64 + "." + $payloadjsonbase64
        $SigningAlgorithm = New-Object System.Security.Cryptography.HMACSHA256
        $SigningAlgorithm.Key = [System.Text.Encoding]::UTF8.GetBytes($SecretKey)
        $Signature = [Convert]::ToBase64String($SigningAlgorithm.ComputeHash([System.Text.Encoding]::UTF8.GetBytes($ToBeSigned))).Split('=')[0].Replace('+', '-').Replace('/', '_')

        #final token for the data
        $token = "$headerjsonbase64.$payloadjsonbase64.$Signature"
    }
    catch {
        Add-Content -Path $LogFile -Value "$(Now) - Signing failed"
        Exit 1
    }

    function Failure {
        $global:helpme = $body
        $global:helpmoref = $moref
        $global:result = $_.Exception.Response.GetResponseStream()
        $global:reader = New-Object System.IO.StreamReader($global:result)
        $global:responsebody = $global:reader.ReadToEnd()
        Write-Host -BackgroundColor Black -ForegroundColor Red "Status: A system exception was caught."
        Write-Host -BackgroundColor Black -ForegroundColor Red $global:responsebody
    }

    #This is to send the request for the API with Authentication
    try {
        $Result = Invoke-WebRequest -Uri $RequestUrl -Method $apiMethod -Body $token -ErrorAction Stop -UseBasicParsing
        $HTTPStatus = $Result.StatusCode
        if ($HTTPStatus.startsWith("2")) {
            Add-Content -Path $LogFile -Value "$(Now) - Authentication was successful because the HTTPStatus code is $HTTPStatus"
            return $Result
        }
        else {
            Add-Content -Path $LogFile -Value "$(Now) - Failed due to the HTTPStatus code being $HTTPStatus"
            Exit 1
        }
    }
    catch {
        $failed = Failure
        Add-Content -Path $LogFile -Value "$(Now) - Authentication failed because $failed"
    }
}

#This matches the serial number with absolutes Console UID
function search {
    param (
        [Parameter(Mandatory)][string]$Serial
    )

    if (-not $Serial) {
        Add-Content -Path $LogFile -Value "$(Now) - Could not grab Serial Number"
        Exit 1
    }

    try {
        $Method = "GET"
        $Uri = "/v3/reporting/devices"
        $Payload = @{}
        $QueryString = "serialNumber=$Serial"
        $search = authenticate -Method $Method -Uri $Uri -QueryString $QueryString -Payload $Payload
        $resp = $search.Content | ConvertFrom-Json
        $uuid = $resp.data.deviceUid
        $agentStatus = $resp.data.agentStatus
         if ($agentStatus -eq "D") {
            Add-Content -Path $LogFile -Value "$(Now) - Device is already unenrolled"
            exit 0
        } else {
            return $uuid
        }
        
    }
    catch {
        Add-Content -Path $LogFile -Value "$(Now) - Failed the search call to find the UUID"
        Exit 1
    }
}

function unenroll {
    param (
        [Parameter(Mandatory)][string]$uuid
    )

    Try {
        $Method = "POST"
        $Uri = "/v3/actions/requests/unenroll"
        $QueryString = ""
        $Payload = @{
            data = @{
                deviceUids           = @("$uuid")
                excludeMissingDevices = $false
            }
        }
        $unfreeze = authenticate -Method $Method -Uri $Uri -QueryString $QueryString -Payload $Payload
        return $unfreeze
    }
    catch {
        Add-Content -Path $LogFile -Value "$(Now) - Could not do the unenroll call"
        Exit 1
    }
}

function agentStatus {
    param (
        [Parameter(Mandatory)][string]$Serial
    )
    try {
        $Method = "GET"
        $Uri = "/v3/reporting/devices"
        $Payload = @{}
        $QueryString = "serialNumber=$Serial"
        $search = authenticate -Method $Method -Uri $Uri -QueryString $QueryString -Payload $Payload
        $resp = $search.Content | ConvertFrom-Json
        $agentStatus = $resp.data.agentStatus

        if ($agentStatus -eq "D") {
            Add-Content -Path $LogFile -Value "$(Now) - Successfully unenrolled the device"
        } else {
            Add-Content -Path $LogFile -Value "$(Now) - Failed to unenroll the device"
        }
    }
    catch {
        Add-Content -Path $LogFile -Value "$(Now) - Failed the search call to find the UUID"
        Exit 1
    }
}

#Grabs serial number
$Serial = (Get-CimInstance Win32_BIOS).SerialNumber.Trim()
Add-Content -Path $LogFile -Value "$(Now) - Serial Number is $Serial"
if (-not $Serial) {
    Add-Content -Path $LogFile -Value "$(Now) - Could not grab Serial Number"
    Exit 1
}

#Starts the search call
Add-Content -Path $LogFile -Value "$(Now) - Starting the search call to find the UUID"
$uuid = search -Serial $Serial
Add-Content -Path $LogFile -Value "$(Now) - Completed the search. The UID is $uuid"

#Starts the Unenroll call
Add-Content -Path $LogFile -Value "$(Now) - Starting the Unenroll call"
$unenroll = unenroll -uuid $uuid
Add-Content -Path $LogFile -Value "$(Now) - Completed the unenroll"

#Start the agentStatus call
Add-Content -Path $LogFile -Value "$(Now) - Starting the agentStatus call to find the UUID"
$agentStatus = agentStatus -Serial $Serial
Add-Content -Path $LogFile -Value "$(Now) - Completed the agentStatus call"