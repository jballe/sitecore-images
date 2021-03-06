function Invoke-Build
{
    [CmdletBinding(SupportsShouldProcess = $true)]
    param(        
        [Parameter(Mandatory = $true)]
        [ValidateScript( { Test-Path $_ -PathType 'Container' })] 
        [string]$Path,
        [Parameter(Mandatory = $true)]
        [ValidateScript( { Test-Path $_ -PathType 'Container' })] 
        [string]$InstallSourcePath,
        [Parameter(Mandatory = $true)]
        [string]$Registry,
        [Parameter(Mandatory = $false)]
        [array]$Tags = @("*"),
        [Parameter(Mandatory = $false)]
        [ValidateSet("WhenChanged", "Always", "Never")]
        [string]$PushMode = "WhenChanged",
        [Parameter(Mandatory = $false)]
        [ValidateSet("Always", "Never")]
        [string]$PullMode = "Always"
    )
    
    # Setup
    $ErrorActionPreference = "STOP"
    $ProgressPreference = "SilentlyContinue"

    # Specify priority for each tag, used to ensure base images are build first. This is the most simple approach I could come up with for handling dependencies between images. If needed in the future, look into something like https://en.wikipedia.org/wiki/Topological_sorting.
    $defaultPriority = 1000
    $priorities = New-Object System.Collections.Specialized.OrderedDictionary
    $priorities.Add("^mssql-developer:(.*)$", 100)
    $priorities.Add("^sitecore-openjdk:(.*)$", 110)
    $priorities.Add("^sitecore-base:(.*)$", 120)
    $priorities.Add("^sitecore-xm1-sqldev:(.*)$", 130)
    $priorities.Add("^sitecore-xm1-pse-(.*)-sqldev:(.*)$", 140)
    $priorities.Add("^sitecore-xm1-pse-(.*)-cm:(.*)$", 150);
    $priorities.Add("^sitecore-xp-sqldev:(.*)$", 160)
    $priorities.Add("^sitecore-xp-base:(.*)$", 170)
    $priorities.Add("^sitecore-xp-xconnect:(.*)$", 180)    
    $priorities.Add("^sitecore-xp-pse-(.*)-sqldev:(.*)$", 190)
    $priorities.Add("^sitecore-xp-pse-(.*)-standalone:(.*)$", 200);
    $priorities.Add("^(.*)$", $defaultPriority)
    
    # Find out what to build
    $unsortedSpecs = Find-BuildSpecifications -Path $Path

    # Update specs, include or not
    $unsortedSpecs | ForEach-Object {
        $spec = $_
        $spec.Include = ($Tags | ForEach-Object { $spec.Tag -like $_ }) -contains $true
    }

    # Update specs, set priority according to rules
    $unsortedSpecs | ForEach-Object {
        $spec = $_
        $rule = $priorities.Keys | Where-Object { $spec.Tag -match $_ } | Select-Object -First 1
    
        $spec.Priority = $priorities[$rule]
    }

    # Update specs, resolve sources to full path
    $unsortedSpecs | ForEach-Object {
        $spec = $_
        $sources = @()

        $spec.Sources | ForEach-Object {
            $sources += (Join-Path $InstallSourcePath $_.Name)
        }
        
        $spec.Sources = $sources
    }

    # Reorder specs, priorities goes first
    $specs = [System.Collections.ArrayList]@()
    $specs.AddRange(@($unsortedSpecs | Where-Object { $_.Priority -lt $defaultPriority } | Sort-Object -Property Priority))
    $specs.AddRange(@($unsortedSpecs | Where-Object { $_.Priority -eq $defaultPriority }))

    # Print results
    $specs | Select-Object -Property Tag, Include, Priority, Base | Format-Table

    # Abort if -WhatIf was used
    if ($WhatIfPreference)
    {
        return
    }

    Write-Host "### Build specifications loaded..." -ForegroundColor Green

    # Pull latest external images
    if ($PullMode -eq "Always")
    {
        $baseImages = @()
        
        # Find external base images of included specifications
        $specs | Where-Object { $_.Include -eq $true } | ForEach-Object {
            $spec = $_

            $spec.Base | Where-Object { $_.Contains("/") -eq $true } | ForEach-Object {
                $baseImages += $_
            }
        }

        # Pull images
        $baseImages | Select-Object -Unique | ForEach-Object {
            $tag = $_

            docker pull $tag

            $LASTEXITCODE -ne 0 | Where-Object { $_ } | ForEach-Object { throw "Failed." }

            Write-Host ("### External image '{0}' is latest." -f $tag)
        }

        Write-Host "### External images is up to date..." -ForegroundColor Green
    }
    else
    {
        Write-Warning ("### Pulling external images skipped since PullMode was '{0}'." -f $PullMode)
    }

    # Start build...
    $specs | Where-Object { $_.Include } | ForEach-Object {
        $spec = $_
        $tag = $spec.Tag

        Write-Host ("### Processing '{0}'..." -f $tag)
    
        # Save the digest of previous builds for later comparison
        $previousDigest = $null
    
        if ((docker image ls $tag --quiet))
        {
            $previousDigest = (docker image inspect $tag) | ConvertFrom-Json | ForEach-Object { $_.Id }
        }

        # Copy license.xml and any missing source files into build context
        $spec.Sources | ForEach-Object {
            $sourcePath = $_
            $sourceItem = Get-Item -Path $sourcePath
            $targetPath = Join-Path $spec.Path $sourceItem.Name

            if (!(Test-Path -Path $targetPath) -or ($sourceItem.Name -eq "license.xml"))
            {
                Copy-Item $sourceItem -Destination $targetPath -Verbose:$VerbosePreference
            }
        }
    
        # Build image
        if ($tag -like "*sql*")
        {
            # Building SQL based images needs more memory than the default 2GB...
            docker image build --isolation "hyperv" --memory 4GB --tag $tag $spec.Path
        }
        else
        {
            docker image build --isolation "hyperv" --tag $tag $spec.Path 
        }

        $LASTEXITCODE -ne 0 | Where-Object { $_ } | ForEach-Object { throw "Failed." }

        # Tag image
        $fulltag = "{0}/{1}" -f $Registry, $tag

        docker image tag $tag $fulltag

        $LASTEXITCODE -ne 0 | Where-Object { $_ } | ForEach-Object { throw "Failed." }

        # Check to see if we need to stop here...
        if ($PushMode -eq "Never")
        {
            Write-Warning ("### Done with '{0}', but not pushed since 'PushMode' is '{1}'." -f $tag, $PushMode)

            return
        }

        # Determine if we need to push
        $currentDigest = (docker image inspect $tag) | ConvertFrom-Json | ForEach-Object { $_.Id }

        if (($PushMode -eq "WhenChanged") -and ($currentDigest -eq $previousDigest))
        {
            Write-Host ("### Done with '{0}', but not pushed since 'PushMode' is '{1}' and the image has not changed since last build." -f $tag, $PushMode) -ForegroundColor Green

            return
        }

        # Push image
        docker image push $fulltag

        $LASTEXITCODE -ne 0 | Where-Object { $_ } | ForEach-Object { throw "Failed." }

        Write-Host ("### Done with '{0}', image pushed." -f $fulltag) -ForegroundColor Green
    }
}

function Find-BuildSpecifications
{
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [ValidateScript( { Test-Path $_ -PathType 'Container' })] 
        [string]$Path
    )

    Get-ChildItem -Path $Path -Filter "build.json" -Recurse | ForEach-Object {
        $buildFilePath = $_.FullName
        $data = Get-Content -Path $buildFilePath | ConvertFrom-Json
        $dockerFile = Get-Item -Path (Join-Path $_.Directory.FullName "\Dockerfile")
        
        # Find base images
        $baseImages = $dockerFile | Get-Content | Where-Object { $_.StartsWith("FROM ") } | ForEach-Object { Write-Output $_.Replace("FROM ", "").Trim() } | ForEach-Object {
            $image = $_

            if ($image -like "* as *")
            {
                $image = $image.Substring(0, $image.IndexOf(" as "))
            }

            if ([string]::IsNullOrEmpty($image))
            {
                throw ("Invalid Dockerfile '{0}', no FROM image was found?" -f $_.FullName)
            }

            Write-Output $image
        }

        if ([string]::IsNullOrEmpty($data.tag))
        {
            throw ("Tag was null or empty in '{0}'." -f $_.FullName)
        }

        $dataSources = @()

        if ($null -ne $data.sources)
        {
            $dataSources = $data.sources
        }

        $sources = @()
        $dataSources | ForEach-Object {
            $source = $_
            $uri = $null
            $name = $source.name;

            if (![string]::IsNullOrEmpty($source.uri))
            {
                if (![System.Uri]::TryCreate(($source.uri).ToString(), [System.UriKind]::Absolute, [ref]$uri))
                {
                    throw ("Parse error in '{0}', string '{1}' is not a valid uri." -f $buildFilePath, $source.uri)
                }
            }

            if ([string]::IsNullOrEmpty($name))
            {
                throw ("Parse error in '{0}', name was null or empty." -f $buildFilePath)
            }
          
            $sources += (New-Object PSObject -Property @{
                    Name = $name;
                    Uri  = $uri;
                })
        }
        
        Write-Output (New-Object PSObject -Property @{
                Tag            = $data.tag;
                Base           = $baseImages;
                Path           = $_.Directory.FullName;
                DockerFilePath = $dockerFile.FullName;
                Sources        = $sources;
                Priority       = $null;
                Include        = $null;
            })
    }
}

function Get-CurrentImages
{
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [ValidateScript( { Test-Path $_ -PathType 'Container' })] 
        [string]$Path
    )
    
    $tagParser = [regex]"(?<repository>.*):(?<version>.*)-(?<os>.*)-(?<build>.*)"

    Find-BuildSpecifications -Path $Path | ForEach-Object {
        $spec = $_
        $match = $tagParser.Match($spec.Tag)

        if ($match.Success)
        {
            $repository = $match.Groups["repository"].Value
            $version = $match.Groups["version"].Value
            $os = $match.Groups["os"].Value
            $build = $match.Groups["build"].Value

            Write-Output (New-Object PSObject -Property @{
                    Repository     = $repository;
                    Version        = $version;
                    OS             = $os;
                    Build          = $build;
                    Tag            = $spec.Tag;
                    DockerFilePath = $spec.DockerFilePath;
                })
        }
    }
}

function Get-CurrentImagesMarkdown
{
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [ValidateScript( { Test-Path $_ -PathType 'Container' })] 
        [string]$Path
    )
    
    Write-Output "| Version | Repository | OS  | Build | Tag |"
    Write-Output "| ------- | ---------- | --- | -----------| --- |"

    Get-CurrentImages -Path $Path | Sort-Object -Property Version, Build, Repository -Descending | ForEach-Object {
        $dockerFileUrl = (Resolve-Path $_.DockerFilePath -Relative).Replace(".\", "").Replace("\", "/").Replace(" ", "%20")

        Write-Output ("| {0} | {1} | {2} | {3 } | ``{4}`` [Dockerfile]({5}) |" -f $_.Version, $_.Repository, $_.OS, $_.Build, $_.Tag, $dockerFileUrl)
    }
}