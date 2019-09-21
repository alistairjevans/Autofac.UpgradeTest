Param(
    # AppVeyor API Key
    [Parameter(Mandatory = $true)]
    [string]
    $appveyorApiKey,
    # The name of the branch (defaults to develop) that the project will be upgraded to.
    # We connect to appveyor to get the latest CI package name.
    [string]
    $autofacCoreBranchName = "develop"    
)

# Find the latest package version on the specified branch.
# Appveyor has the actual package name
$apiUrl = 'https://ci.appveyor.com/api';
$token = $appveyorApiKey;
$headers = @{
"Authorization" = "Bearer $token"
"Content-type" = "application/json"
};
$accountName = 'Autofac';
$projectSlug = 'autofac';

# get project with last build details
$appveyorProject = Invoke-RestMethod -Method Get -Uri "$apiUrl/projects/$accountName/$projectSlug/branch/$autofacCoreBranchName" -Headers $headers

if(!$appveyorProject)
{
    Write-Error("Could not locate branch, or api key is invalid.");
    exit;
}

# we assume here that build has a single job
# get this job id
$jobId = $appveyorProject.build.jobs[0].jobId

# get job artifacts (just to get the outputted package name)
$artifacts = Invoke-RestMethod -Method Get -Uri "$apiUrl/buildjobs/$jobId/artifacts" -Headers $headers

$nugetPackageFileName = Split-Path $artifacts[0].fileName -Leaf

# Get the version from the nupkg name
$match = [Regex]::Match($nugetPackageFileName, "Autofac\.(?<version>.+)\.nupkg");

if(!$match.Success)
{
    Write-Error "Cannot get Autofac version."
    exit;
}

return $match.Groups["version"].Value;