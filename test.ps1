param(
	[Parameter(Mandatory = $true)] $DestinationCluster,

	[Parameter(Mandatory = $true)] $DestinationVserver,

	[Parameter(Mandatory = $true)] $DestinationVolume,

	[Parameter(Mandatory = $false)] $ClearCheckpoint
)

Function Invoke-WebResponse {
	param(
		[Parameter(Mandatory = $true)] $request
	)
	
	$junk = [System.Reflection.Assembly]::LoadWithPartialName("System.Web")
	
	Try {
		$response = $request.GetResponse()
	} Catch [System.Net.WebException] {
		$ex = $_.Exception.Response.StatusCode
		$response.Close()
		Throw "Workflow not found - Exception from server: $ex"
	} Catch [System.Exception] {
		$response.Close()
		Throw "Some other random error..$($_.Exception)"
	}
	
	$readStream = $response.GetResponseStream()
	$reader = New-Object System.IO.StreamReader($readStream)
	
	Try {
		$output = [xml] $reader.readtoend()
	} Catch {
		Throw "Exception reading stream from server.  Exception: $($_.Exception)"
	} Finally {
		$response.Close()
		$reader.Close()
	}
	return $output
}

Function Invoke-WFAGet {
	param(
		[Parameter(Mandatory = $true)] $url,
		[Parameter(Mandatory = $true)] $cred
	)
	
	$junk = [System.Reflection.Assembly]::LoadWithPartialName("System.Web")
	$request = [System.Net.HttpWebRequest]::Create($url)
	$request.Credentials = $cred
	
	return $(Invoke-WebResponse -request $request)
}


Function Invoke-WFAPut {
	param(
		[Parameter(Mandatory=$true)] $url,
		[Parameter(Mandatory=$true)] $cred,
		[Parameter(Mandatory=$true)] [xml] $xml
	)
	
	$junk = [System.Reflection.Assembly]::LoadWithPartialName("System.Web")
	$request = [System.Net.HttpWebRequest]::Create($url)
	$request.Credentials = $cred
	$request.Method = "POST"
	$request.ProtocolVersion = "1.0"
	$request.ContentType = "application/xml"

	# Create the input stream to the REST API
	$requestInputStream = $request.GetRequestStream()

	# Create a stream writer to write the XML
	$writer = New-Object System.IO.StreamWriter($requestInputStream)
	$writer.AutoFlush = $true

	# Write the XML
	Try {
		$writer.Write($($xml.OuterXml))
	} Catch [System.IO.IOException] {
		Throw "Cannot write to stream. Exception $($_.Exception)"
	} Catch [System.Exception] {
		Throw "Some other weird error caught...$($_.Exception)"
	} Finally {
		$writer.Close()
	}
	return $(Invoke-WebResponse -request $request)
}

Function Get-WFALinks {
	param(
		[Parameter(Mandatory = $true)] $linkList,
		[Parameter(Mandatory = $true)] $linkToFind
	)
	<#
	Find the link requested.  The documentation does not appear to 
	be reliable in this manner as the order is not correctly documented
	in the original REST document on the communities site.  So in order
	to avoid executing the wrong link by having a hard reference, we build
	a function to search for the link in the list.
	#>
	for($x = 0 ; $x -lt $linkList.Count; $x++) {
		if($($linkList[$x]).rel -match $linkToFind) {
			$href = $($linkList[$x]).href
			break
		}
	}
	return $href
}

Function Get-InArray {
	param(
		[Parameter(Mandatory=$true)] $find,
		[Parameter(Mandatory=$true)] [array] $inA
	)
	<#
	Stupid function to fix the lack of the -in operator in 
	PoSH 2.0
	#>
	foreach ($item in $inA) {
		if($find -match $item -or $find -eq $item) { return $true }
	}
	return $false
}

Function Get-WFAJobStatus {
	param(
		[Parameter(Mandatory=$true)] $status
	)
	$badStat = @("FAILED", "ABORTING", "CANCELED", "OBSOLETE")
	$okStat = @("PAUSED", "RUNNING", "PENDING", "SCHEDULED", "EXECUTING")
	$doneStat = "COMPLETED"
	if($(Get-InArray -find $status -inA $okStat)) { 
		return "OK"
	} elseif ($status -match $doneStat) {
		return "DONE"
	} elseif ($(Get-InArray -find $status -inA $badStat)) {
		return "FAILED"
	} else {
		return "UNKNOWN"
	}
}

<#
******************************************************************************************************
************************ ONLY ALTER THIS PORTION OF THE CODE!!! **************************************
******************************************************************************************************
#>
$xmlOut = [xml] @"
<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
	<workflowInput>
		<userInputValues>
			<userInputEntry key = "DestinationCluster" value = "$DestinationCluster"/>
			<userInputEntry key = "DestinationVserver" value = "$DestinationVserver"/>
			<userInputEntry key = "DestinationVolume" value = "$DestinationVolume"/>
			<userInputEntry key = "ClearCheckpoint" value = "$ClearCheckpoint"/>
		</userInputValues>
	</workflowInput>
"@
<#
******************************************************************************************************
******************************* DO NOT ALTER ANYTHING BELOW HERE!!!! *********************************
******************************************************************************************************
#>

# Setup the core for the script.  Dont change the URL unless you are remotely executing
# or have a non-default port.
$junk = [System.Reflection.Assembly]::LoadWithPartialName("System.Web")
$sleepTime = 10

$wfaHost = "localhost"
$url = "http://" + $wfaHost + "/rest/workflows"
$cred = Get-WFACredentials -Host $wfaHost
$workflowToExecute = "Abort SnapMirror"
Get-WFALogger -Info -Message $("Executing workflow $workflowToExecute via REST")

# Build the URI to test if this workflow actually exists and to get the 'execute' href
$newUrl = $url + "?name=" + $([System.Web.HttpUtility]::UrlEncode($workflowToExecute))
Get-WFALogger -Info -Message $("URL: $newUrl")

# Get the workflow information
$workflow = $(Invoke-WFAGet -url $newUrl -cred $cred).collection.workflow

# Derive the href for "execute"
$href = Get-WFALinks -linkList $($workflow.link) -linkToFind "execute"

# Invoke the PUT with the execute href and the XML
$output = Invoke-WFAPut -url $href -cred $cred -xml $xmlOut
sleep $sleepTime
$status = Get-WFAJobStatus -status $($output.job.jobStatus.jobStatus)

if($status -match "OK" -or $status -match "DONE") {
	# Get the href so we can get status of the job
	$href = Get-WFALinks -linkList $($output.job.link) -linkToFind "self"
	
	while($status -match "OK") {
		$rawStatus = Invoke-WFAGet -url $href -cred $cred
		$status = Get-WFAJobStatus -status $($rawStatus.job.jobStatus.jobStatus)
		$step = $rawStatus.job.jobStatus."workflow-execution-progress"."current-command-index"
		$ofStep = $rawStatus.job.jobStatus."workflow-execution-progress"."commands-number"
		Get-WFALogger -Info -Message $("Workflow Execution Current Status: $status.  Executing command number $step of $ofStep")
		sleep $sleepTime
	}
	
	switch($status) {
		"DONE" {
			Get-WFALogger -Info -Message $("Workflow $workflowToExecute completed successfully")
			exit 0
		}
		"FAILED" {
			Get-WFALogger -Error -Message $("Workflow $workflowToExecute failed.")
			exit 1
		}
		"UNKNOWN" {
			Get-WFALogger -Error -Message $("Indeterminate status.  Status returned was $status")
			exit 2
		}
	}
} else {
	WFA-Logger -Error -Message $("Workflow $workflowToExecute failed to start!  Status was: $status")
	exit 3
}
