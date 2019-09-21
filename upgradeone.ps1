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
    # The location to place the generated test report (minus the extension),
    # this will vary based on project type.
    [string]
    $outputReport
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
    $exactPackageVersion = .\getLatestPackageForBranch.ps1 -appveyorApiKey $appveyorApiKey -autofacCoreBranchName $autofacCoreBranchName;
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
    $majorVersion = $sdkVersion -split '-' | Select-Object -First 1;

    if($majorVersion -eq "1.0.0")
    {
        dotnet restore
        dotnet build **/project.json
    }
    else
    {
        # Shutdown the build server, because some tasks in packages may have been updated
        # Errors may happen here if we are pre 2.1
        dotnet build-server shutdown

        dotnet build 
    }

    if($LastExitCode -ne 0)
    {
        "E: Failed Build";
        exit;
    }

    # Find all the test projects
    $testProjects = Get-ChildItem "test/**/*.csproj","test/**/project.json";
    
    if(!$testProjects)
    {
        "S: Build Passed - No test projects"
    }

    foreach ($testProj in $testProjects) 
    {
        if($majorVersion -eq "1.0.0")
        {
            $resultsNet10 = "";

            # No logger here, all we can do is look for the summary line
            dotnet test $testProj.FullName | Tee-Object -Variable "resultsNet10";

            $resultsNet10 = $resultsNet10 | Select-Object -Last 1;

            if($resultsNet10 -match "Passed: (\d+), Failed: (\d+)")
            {
                $passedTests = $Matches[1];
                $failedTests = $Matches[2];

                if($failedTests -eq 0)
                {
                    "S: All $passedTests test targets passed for $($testProj.Directory.Name)"
                }
                else 
                {
                    "E: $failedTests test targets failed, $passedTests test targets passed for $($testProj.Directory.Name). Check log for details."
                }
            }
            else {
                "E: Could not read test results for .NET Core 1.0.0 tests"
            }
        }
        else 
        {    
            $reportFile = "${outputReport}_$($testProj.BaseName).trx";

            if(![System.IO.Path]::IsPathRooted($reportFile))
            {
                $location = Get-Location;
                $reportFile = Join-Path $location $reportFile;
            }
        
            Remove-Item $reportFile -ErrorAction SilentlyContinue
            # We can't use exit codes for dotnet test, because it can succeed on the test execution but still
            # give a failing code because of SDK configuration inside the projects. So we'll check the TRX file.
            dotnet test $testProj.FullName --no-build --logger "trx;LogFileName=$reportFile"
    
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
                        "E: $failedTests test(s) failed, $passedTests test(s) passed for $($testProj.BaseName)"
                    }
                }
                else 
                {
                    "E: Could not parse TRX file for $($testProj.BaseName) to find ResultSummary/Counters, assuming failure"
                }
            }
            else 
            {
                "W: No test report generated for $($testProj.BaseName), possible failure or may not be a test project"
            }   
        }
    }
}
else 
{
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

    # Need to update the assembly redirects in any app.config files
    # For this we need the non-prerelease version info
    $majorPart = $exactPackageVersion -split '-' | Select-Object -First 1;

    # Go find all the App.config files in the test folder
    $allAppConfigs = Get-ChildItem "test" -Filter "App.config" -Recurse;

    foreach ($cfg in $allAppConfigs) {
        
        [xml] $loadedAppConfig = Get-Content $cfg.FullName -Raw;

        $assemblyBinding = $loadedAppConfig.configuration.runtime.assemblyBinding;

        [System.Xml.XmlNamespaceManager]$ns = $loadedAppConfig.NameTable
        $ns.AddNamespace("b", $assemblyBinding.NamespaceURI)
    
        $assemblyIdentity = $assemblyBinding.SelectSingleNode("b:dependentAssembly/b:assemblyIdentity[@name='Autofac']", $ns)
        
        if($assemblyIdentity)
        {
            $assemblyIdentity.NextSibling.newVersion = "$majorPart.0";
            $loadedAppConfig.Save($cfg.FullName);
        }

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
       
        & $xunitRunner.FullName $testDllPath -html "$outputReport.html"
        
        if($LastExitCode -ne 0)
        {
            "E: Failing tests"
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

