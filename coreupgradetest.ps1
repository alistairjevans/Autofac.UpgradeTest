Param(
    # Specify the checked-out path to work on
    [string]
    $checkoutDir,
    # If you specify an appveyor API key, we'll go and figure out the exact package name
    [string]
    $appveyorApiKey,
    # The name of the branch (defaults to develop, that the project will be upgraded to),
    # we connect to appveyor to get the latest CI package name.
    [string]
    $autofacCoreBranchName = "develop",
    # If you don't want to use appveyor, you can specify the exact package version here
    # and we'll grab it from MyGet (e.g. 4.9.2-pr-immutab-000635).
    [string]
    $exactPackageVersion,
    # The location to place the generated test report
    [string]
    $testOutputReportFile
)

$ErrorActionPreference = "Stop";
Set-ExecutionPolicy Bypass -Scope Process;

if(!$checkoutDir)
{
    $checkoutDir = Get-Location;
}

if ($null -eq (Get-Command "nuget.exe" -ErrorAction SilentlyContinue)) 
{
    Write-Error "Need nuget in path"
    exit;
}

if ($null -eq (Get-Command "dotnet.exe" -ErrorAction SilentlyContinue)) 
{
    Write-Error "Need dotnet in path"
    exit;
}

if($appveyorApiKey)
{
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

    $exactPackageVersion = $match.Groups["version"].Value;
}
elseif (!$exactPackageVersion) {
    
    Write-Error "Need to provide appveyor key or the exact package version."
    exit;
}

Push-Location $checkoutDir

# Apply a fixed NuGet config
Copy-Item "$PSScriptRoot\NuGet.config" ".\NuGet.config" -FOrce

$inCoreProject = $false;

# See if we need to install the dotnet SDK
if(Test-Path "global.json")
{
    $inCoreProject = $true;

    $globalJsonFile = Get-Content "global.json" | ConvertFrom-Json;
    
    $sdkVersion = $globalJsonFile.sdk.version;

    # Back to the root to install the SDK
    Push-Location $PSScriptRoot

    .\dotnet-install.ps1 -Version $sdkVersion -InstallDir "temp_sdk" -SkipNonVersionedFiles;

    Pop-Location
}

# So it turns out that it's incredibly difficult to update nuget packages automatically
# in a way that works consistently. So we're going to just load the XML and update it ourselves.
# Not everything uses packagereferences either, so we'll need to update that.

# See if there are any packages.config files
$packageConfigFiles = Get-ChildItem packages.config -Recurse

if($packageConfigFiles)
{
    # Need the sln file.
    $slnFile = Get-ChildItem "*.sln";

    nuget restore

    # Old style, just update the nuget packages using the CLI
    nuget update $slnFile.Name -Id Autofac -Version $exactPackageVersion

    if($LastExitCode -ne 0)
    {
        "E: Failed to update nuget package"
        exit;
    }
}
else 
{

    # Locate all projects that contain an Autofac reference
    $childProjects = Get-ChildItem *.csproj -Recurse;

    $knownXunitVersion = $null;

    foreach($proj in $childProjects)
    {   
        [xml] $projContent = Get-Content $proj.FullName -Raw;

        [System.Xml.XmlNamespaceManager]$ns = $projContent.NameTable
        $ns.AddNamespace("MsBuild", $projContent.DocumentElement.NamespaceURI)
    
        $versionNode = $projContent.SelectSingleNode("//MsBuild:PackageReference[@Include='Autofac']", $ns)

        if($versionNode)
        {
            $versionNode.Version = $exactPackageVersion;
            $projContent.Save($proj.FullName);
        }
        else 
        {
            # Need to add the reference from scratch. Use dotnet for this bit
            dotnet add $proj.FullName package Autofac --version $exactPackageVersion;    
        }

        # Also look for an xunit console runner package, so we know which version to use.
        $xunitReference = $projContent.SelectSingleNode("//MsBuild:PackageReference[@Include='xunit.runner.console']", $ns)
        
        if($xunitReference)
        {
            # We'll need this later if we are doing a non-core test.
            $knownXunitVersion = $xunitReference.Version;
        }
    }
}

if($inCoreProject)
{
    # Shutdown the build server, because some tasks in packages may have been updated
    # Don't catch errors here, because the installed dotnet instance may not have the build-server tool.
    dotnet build-server shutdown | Out-Null

    dotnet build 

    if($LastExitCode -ne 0)
    {
        "E: Failed Build";
        exit;
    }

    # Find all the test projects
    $testProjects = Get-ChildItem "test/**/*.csproj";
    
    if(!$testProjects)
    {
        "S: Build Passed - No test projects"
    }

    foreach ($testProj in $testProjects) 
    {
        $reportFile = "${testOutputReportFile}_$($testProj.BaseName).trx";

        if(![System.IO.Path]::IsPathRooted($reportFile))
        {
            $location = Get-Location;
            $reportFile = Join-Path $location $reportFile;
        }
    
        Remove-Item $reportFile -ErrorAction SilentlyContinue
    
        dotnet test $testProj.FullName --no-build --logger "trx;LogFileName=$reportFile"
    
        # We can't use exit codes for dotnet test, because it can succeed on the test execution but still
        # give a failing code because of SDK configuration inside the projects. So we'll check the TRX file.
    
        if(Test-Path $reportFile)
        {
            [xml] $loadedTrx = Get-Content $reportFile -Raw;
    
            $counters = $loadedTrx.TestRun.ResultSummary.Counters;
    
            if($counters)
            {
                $failedTests = $counters.failed;
                $passedTests = $counters.passed;

                if($failedTests -eq 0)
                {
                    "S: All $passedTests tests passed for $($testProj.BaseName)"
                }
                else 
                {
                    "E: $failedTests test(s) failed, $passedTests test(s) passed for $($testProj.BaseName). Report at $reportFile"
                }
            }
            else 
            {
                "E: Could not parse TRX file for $($testProj.BaseName) to find ResultSummary/Counters, assuming failure."
            }
        }
        else 
        {
            "W: No test report generated for $($testProj.BaseName), possible failure or may not be a test project."
        }        
    }
}
else {
    # Need to do a regular nuget restore to get msbuild working
    nuget restore

    # Look for vswhere in the path
    if (Get-Command "vswhere.exe" -ErrorAction SilentlyContinue)
    {
        $msbuildExe = vswhere -latest -requires Microsoft.Component.MSBuild -find MSBuild\**\Bin\MSBuild.exe | select-object -first 1
    }
    else 
    {
        $tempTools = Join-Path $PSScriptRoot "temp_tools";

        $vsWhereExe = Join-Path $tempTools "vswhere.*/tools/vswhere.exe"; 

        if(!(Test-Path $vsWhereExe))
        {
            # Get vswhere
            nuget install vswhere -OutputDirectory $tempTools
        }   

        $vsWhereExe = Resolve-Path $vsWhereExe;

        $msbuildExe = & $vsWhereExe -latest -requires Microsoft.Component.MSBuild -find MSBuild\**\Bin\MSBuild.exe | select-object -first 1
        
    }

    & $msbuildExe -t:Rebuild -p:Configuration=Release

    if($LastExitCode -ne 0)
    {
        "E: Failed Build"
        exit;
    }

    $testDllPath = Resolve-Path test/*/bin/Release/*.Test.dll -ErrorAction SilentlyContinue

    if($testDllPath)
    {
        if($packageConfigFiles)
        {
            $xunitRunner = Get-ChildItem -Path "packages\xunit.runner.console.*" -Filter "xunit.console.exe" -Recurse | Select -First 1

            if(!$xunitRunner)
            {
                # No xunit runner (not all the projects have a console runner installed)
                # So lets add one.
                nuget install xunit.runner.console -OutputDirectory packages

                $xunitRunner = Get-ChildItem -Path "packages\xunit.runner.console.*" -Filter "xunit.console.exe" -Recurse | Select -First 1;
            }
        }
        else 
        {
            if(!$knownXunitVersion)
            {
                "E: Could not determine XUnit version";
                exit;
            }
            # Locate xunit 
            $xunitRunner = Get-ChildItem -Path "${env:USERPROFILE}\.nuget\packages\xunit.runner.console\$knownXunitVersion\tools\" -Filter "xunit.console.exe" -Recurse | Select -First 1;
        }
       
        & $xunitRunner.FullName $testDllPath -html "$testOutputReportFile.html"
        
        if($LastExitCode -ne 0)
        {
            "E: Failing tests (report at $testOutputReportFile.html)"
        }
        else 
        {
            "S: All tests passed"
        }
    }
    else 
    {
        "S: Build Passed - No test project"
    }
}

Pop-Location

