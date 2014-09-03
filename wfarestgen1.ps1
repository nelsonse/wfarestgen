Function Get-WfaScript {
	param(
		[Parameter(Mandatory = $true)] $userInput,
		[Parameter(Mandatory = $true)] $scriptFile
	)
	
	if($($(Get-ChildItem $scriptFile -ErrorAction SilentlyContinue).Name).Length -gt 0) {
		Write-Warning "Script file $scriptFile already exists.  Deleting"
		Remove-Item -Path $scriptFile -Force
	}
	
	foreach ($line in $(Get-Content -Path ".\calltemplate.txt")) {
		if($line -cmatch "^<param>$") {
			Publish-WfaParams -userInput $userInput -scriptFile $scriptFile
			continue
		} 
		
		if ($line -cmatch "^<xml>$") {
			Publish-WfaXml -userInput $userInput -scriptFile $scriptFile
			continue
		}

		Out-File -FilePath $scriptFile -InputObject $line -Append
	}
}

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

Function Publish-WfaXml {
	param(
		[Parameter(Mandatory = $true)] $userInput,
		[Parameter(Mandatory = $true)] $scriptFile
	)
	
	$xmlTopTempArray = @("<?xml version=`"1.0`" encoding=`"UTF-8`" standalone=`"yes`"?>", "`t<workflowInput>", "`t`t<userInputValues>")
	$xmlBotTempArray = @("`t`t</userInputValues>", "`t</workflowInput>")
	$userInputTemplate = "<userInputEntry key = ""--userInputName--"" value = ""$--userInputName--""/>"

	foreach ($userInputItem in $userInput) {
		$inputTemplate = $userInputTemplate -replace "--userInputName--", $userInputItem.name
		$xmlTopTempArray += $("`t`t`t" + $inputTemplate)
	}
	$xmlTempArray = $xmlTopTempArray + $xmlBotTempArray
	foreach ($line in $xmlTempArray) {
		Out-File -Append -FilePath $scriptFile -InputObject $line
	}
	return
}

Function Publish-WfaParams {
	param(
		[Parameter(Mandatory = $true)] $userInput,
		[Parameter(Mandatory = $true)] $scriptFile
	)
	
	$paramTempArray = @("param(")
	$userInputTemplate = "`t[Parameter(Mandatory = $--mandatory--)] $--userInputName--"
	for ($x = 0; $x -lt $($userInput).count; $x++) { 
		$inputTemplate = $userInputTemplate -replace "--userInputName--", $($userInput[$x]).name
		$inputTemplate = $inputTemplate -replace "--mandatory--", $($userInput[$x]).mandatory
		if($x -ne ($userInput.count - 1)) {
			$paramTempArray += $($inputTemplate + ",`n")
		} else {
			$paramTempArray += $inputTemplate
		}
	}
	
	foreach ($line in $paramTempArray) {
		Out-File -Append -FilePath $scriptFile -InputObject $line
	}
	Out-File -Append -FilePath $scriptFile -InputObject ")"
	return 
}

Function Publish-WfaRestScript {
}

# Setup the core for the script.  Dont change the URL unless you are remotely executing
# or have a non-default port.
$junk = [System.Reflection.Assembly]::LoadWithPartialName("System.Web")
$sleepTime = 5
$wfaHost = Read-Host "Enter host name for WFA Server or 'localhost'"
$user = Read-Host "Enter admin user for WFA"
$pw = Read-Host -AsSecureString "Enter password for admin user"
while($uuidOrName -notmatch "(uuid)|(name)") {
	$uuidOrName = Read-Host "Select 'name' or 'uuid' for workflow selection"
}

if($uuidOrName -match "name") {
	$workflowToExecute = Read-Host "Enter complete human readable name"
	$urlExt = "?name=" + $([System.Web.HttpUtility]::UrlPathEncode($workflowToExecute))
} else {
	$uuidToExecute = Read-Host "Enter UUID to search for"
	$urlExt = "/" + $([System.Web.HttpUtility]::UrlPathEncode($uuidToExecute))
}

$scriptName = Read-Host "Script name to create"
if(-not $scriptName.Contains("ps1")) {
	$scriptName = $scriptName + ".ps1"
}

# Base URL
$url = "http://" + $wfaHost + "/rest/workflows"

# WFA Credentials...
$cred = New-Object System.Management.Automation.PSCredential($user, $pw)

# Build the URI to test if this workflow actually exists
$newUrl = $url + $urlExt

# Get the workflow information
if($uuidOrName -match "name") {
	$workflow = $(Invoke-WFAGet -url $newUrl -cred $cred).collection.workflow
} else {
	$workflow = $(Invoke-WFAGet -url $newUrl -cred $cred).workflow
}

#$restXml = Publish-WfaXml -userInput $($workflow.userInputList.userInput)
#$restParams = Publish-WfaParams -userInput $($workflow.userInputList.userInput)
$script = Get-WfaScript -userInput $($workflow.userInputList.userInput) -scriptFile $scriptName
