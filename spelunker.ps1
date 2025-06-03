#!/usr/bin/env pwsh

param(
    [string]$Path = "www/news",
    [string]$Command,
    # Parameter for Invoke-Post, path to the .htmraw file to process or create
    [string]$PostHtmRawPathParameter,
    [string]$PostFilePath, # Alias/legacy name for PostHtmRawPathParameter for Invoke-Post
    # Parameter for Invoke-Edit, path to the .htmraw file to edit
    [Parameter(Mandatory = $false, HelpMessage = "Path to the .htmraw file to edit.")]
    [Alias("EditFilePath")]
    [string]$EditHtmRawPathParameter,
    [Parameter(Mandatory = $false, HelpMessage = "Run the script in interactive TUI mode.")]
    [switch]$Interactive,
    [Parameter(Mandatory = $false, HelpMessage = "Displays this help message and exits.")]
    [Alias("h", "?")]
    [switch]$Help
)

# Handle -Help switch immediately after parameters are bound
if ($PSBoundParameters.ContainsKey('Help')) {
    Show-SpelunkerHelp
    exit 0 # Exit successfully after displaying help
}

# Set interactive mode global flag
$Global:IsInteractiveMode = if ($Interactive.IsPresent) { $true } else { $false }
Write-Verbose "Interactive mode set to: $Global:IsInteractiveMode"

# --- Function to Initialize/Re-initialize Global Path Variables ---
function Set-GlobalPathVariables {
    param (
        [Parameter(Mandatory=$true)]
        [string]$BaseContentPathFromParam # This is the value from -Path or user input
    )

    # Resolve ContentRoot: if $BaseContentPathFromParam is absolute, use it directly. Otherwise, join with script's parent directory.
    if ([System.IO.Path]::IsPathRooted($BaseContentPathFromParam)) {
        $Global:ContentRoot = $BaseContentPathFromParam
    } else {
        $Global:ContentRoot = Join-Path -Path $PSScriptRoot -ChildPath $BaseContentPathFromParam
    }
    # Attempt to resolve to a full, canonical path.
    $Global:ContentRoot = (Resolve-Path -Path $Global:ContentRoot -ErrorAction SilentlyContinue).Path
    if (-not $Global:ContentRoot) {
        Write-Warning "The specified content path '$BaseContentPathFromParam' could not be resolved. Some operations may fail."
        # Fallback to a non-resolved path or handle error more gracefully if needed
        if ([System.IO.Path]::IsPathRooted($BaseContentPathFromParam)) { $Global:ContentRoot = $BaseContentPathFromParam }
        else { $Global:ContentRoot = Join-Path -Path $PSScriptRoot -ChildPath $BaseContentPathFromParam }
    }

    # Define other paths based on the (potentially overridden) ContentRoot
    $Global:TemplatesDir = Join-Path -Path $Global:ContentRoot -ChildPath "cms_config"
    $Global:HeaderTemplate = Join-Path -Path $Global:TemplatesDir -ChildPath "cms_header.txt"
    $Global:FooterTemplate = Join-Path -Path $Global:TemplatesDir -ChildPath "cms_footer.txt"
    $Global:BeginTemplate = Join-Path -Path $Global:TemplatesDir -ChildPath "cms_begin.txt"
    $Global:EndTemplate = Join-Path -Path $Global:TemplatesDir -ChildPath "cms_end.txt"
    $Global:SkeletonTemplate = Join-Path -Path $Global:TemplatesDir -ChildPath "cms_skeleton.txt"
    $Global:IndexFile = Join-Path -Path $Global:ContentRoot -ChildPath "index.html"
    $Global:AllPostsFile = Join-Path -Path $Global:ContentRoot -ChildPath "all_posts.html"
    $Global:AllTagsFile = Join-Path -Path $Global:ContentRoot -ChildPath "all_tags.html"

    Write-Verbose "Global paths re-initialized. ContentRoot: $($Global:ContentRoot)"
    Write-Verbose "TemplatesDir: $($Global:TemplatesDir), IndexFile: $($Global:IndexFile)"
}

# --- Initial Setup of Global Variables ---

# --- Path and Asset Helper Functions ---
function Determine-PageDepth {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$true)]
        [string]$PagePath,

        [Parameter(Mandatory=$true)]
        [string]$BaseSitePath
    )

    Write-Verbose "Determining page depth for '$PagePath' relative to '$BaseSitePath'..."

    $resolvedPagePath = (Resolve-Path -LiteralPath $PagePath -ErrorAction SilentlyContinue).ProviderPath
    $resolvedBasePath = (Resolve-Path -LiteralPath $BaseSitePath -ErrorAction SilentlyContinue).ProviderPath

    if (-not $resolvedPagePath -or -not $resolvedBasePath) {
        Write-Warning "Could not resolve one or both paths: Page='$PagePath', Base='$BaseSitePath'. Returning depth 0."
        return 0
    }

    # Ensure base path ends with a separator for correct substring and comparison
    $normalizedBasePath = $resolvedBasePath
    if (-not ($normalizedBasePath.EndsWith("\") -or $normalizedBasePath.EndsWith("/"))) {
        $normalizedBasePath += [System.IO.Path]::DirectorySeparatorChar
    }

    if (-not $resolvedPagePath.StartsWith($normalizedBasePath, [System.StringComparison]::InvariantCultureIgnoreCase)) {
        Write-Warning "Page path '$resolvedPagePath' does not start with base path '$normalizedBasePath'. Cannot determine depth accurately. Returning depth 0."
        return 0
    }

    $relativePathString = $resolvedPagePath.Substring($normalizedBasePath.Length)
    $normalizedRelativePath = $relativePathString.TrimStart('\/')

    Write-Verbose "Normalized relative path: '$normalizedRelativePath'"

    if ([string]::IsNullOrWhiteSpace($normalizedRelativePath) -or $normalizedRelativePath -notlike "*[\/\\]*") {
        # File is directly in the base path or is the base path itself (if PagePath was a dir)
        # Or if it's a file in root and normalizedRelativePath is just "filename.html"
        # We are interested in directory depth of the *file's location*.
        # So, if normalizedRelativePath doesn't contain any separators, its *directory* is the root.
        $parentDirRelativePath = Split-Path -Path $normalizedRelativePath
        if ([string]::IsNullOrWhiteSpace($parentDirRelativePath)) {
            Write-Verbose "Depth calculated as 0 (file in root or no directory segments)."
            return 0
        }
        $normalizedRelativePath = $parentDirRelativePath # Now consider only the directory part for depth
    }

    # Split by both types of slashes just in case, though PowerShell paths are usually consistent
    $segments = $normalizedRelativePath.Split(@('\', '/'), [System.StringSplitOptions]::RemoveEmptyEntries)
    $depth = $segments.Count

    # If the original PagePath was a directory (e.g. ContentRoot itself for index.html),
    # segments.Count might be 0 if normalizedRelativePath was empty.
    # However, for a file like "index.html" in root, normalizedRelativePath is "index.html",
    # Split-Path gives "", segments.Count on "" is 0. This is correct (depth 0).
    # For "sub/index.html", normalizedRelativePath is "sub/index.html", Split-Path gives "sub", segments.Count on "sub" is 1. Correct.

    Write-Verbose "Determined page depth for '$PagePath' as $depth."
    return $depth
}

function Adjust-AssetPaths {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$true)]
        [string]$HtmlContentString,

        [Parameter(Mandatory=$true)]
        [int]$PageDepth
    )

    if ($PageDepth -eq 0) {
        Write-Verbose "Page depth is 0, no asset path adjustment needed."
        return $HtmlContentString
    }

    $prefix = ("../" * $PageDepth) # PowerShell string multiplication
    Write-Verbose "Adjusting asset paths for depth $PageDepth using prefix '$prefix'."

    $adjustedHtml = $HtmlContentString
    $assetFoldersToAdjust = @("images0", "css0") # Add other root asset folders here if needed

    foreach ($folderName in $assetFoldersToAdjust) {
        # Regex explanation:
        # (?i) : Case-insensitive match
        # (<(?:a|link|img|script|iframe|source)[^>]*?) : Group 1: Capture the opening tag part (e.g. <a ... or <img ...)
        # (?:href|src)\s*=\s* : Non-capturing group for href= or src= with optional whitespace
        # ([`"']) : Group 2: Capture the opening quote (single, double, or backtick)
        # ($folderName)/ : Group 3: Capture the specific folder name followed by a slash (e.g. images0/)
        $regexPattern = "(?i)(<(?:a|link|img|script|iframe|source)[^>]*?(?:href|src)\s*=\s*([`"']))($folderName)/"
        $replacementPattern = '${1}' + $prefix + '${3}/' # Prepend prefix to the folder name

        $adjustedHtml = [regex]::Replace($adjustedHtml, $regexPattern, $replacementPattern)
    }

    return $adjustedHtml
}


# --- HTML Generation Helper Functions ---

function Get-SearchBoxHtml {
    [CmdletBinding()]
    param()
    Write-Verbose "Generating search box HTML..."
    $formHtml = ""
    if ([string]::IsNullOrWhiteSpace($Global:SearchBoxEngine) -or $Global:SearchBoxEngine -eq 'none') {
        return "" # No search box if engine is none or not set
    }

    # Remove http(s):// from CmsUrl for sitesearch parameter if needed by engine
    $baseCmsUrlForSearch = $Global:CmsUrl -replace 'https?://([^/]+).*', '$1' # Extracts domain for site search
    # If CmsUrl is just a relative path like "news", this might need adjustment or use SiteUrl's domain.
    # For simplicity, assuming CmsUrl is a full URL from which domain can be extracted.
    # If $Global:CmsUrl itself is used as the value for sitesearch, it might work for Google too.
    # Let's use the specific domain as per typical Google "sitesearch" usage.
    # If SiteUrl is more appropriate for a site-wide search, that logic would go here.

    switch ($Global:SearchBoxEngine.ToLowerInvariant()) {
        "google" {
            # For Google, sitesearch value should typically be the domain e.g. "example.com"
            # or a specific path prefix e.g. "example.com/news"
            $searchDomain = $Global:CmsUrl -replace 'https?://' # Remove protocol
            if ($searchDomain.Contains("/")) {
                 $searchDomain = $searchDomain.Substring(0, $searchDomain.IndexOf("/")) # Get only domain part if path exists
            }
            # If CmsUrl was just a relative path, this logic needs to be smarter or rely on SiteUrl
            # For now, assuming CmsUrl is like http://domain.com/path
            # A safer bet for sitesearch might be just the domain of SiteUrl.
            $siteSearchValue = $Global:SiteUrl -replace 'https?://([^/]+).*', '$1'


            $formHtml = "<form class=""field has-addons"" action=""https://www.google.com/search"" method=""get"" target=""_blank"" style=""float:right;"">"
            $formHtml += "<div class=""control""><input class=""input is-small mt-1"" type=""text"" name=""q"" placeholder=""Search..."" style=""width:$($Global:SearchBoxWidth)ch;""></div>" # Using 'ch' for character width
            $formHtml += "<input type=""hidden"" name=""sitesearch"" value=""$siteSearchValue"">" # Google specific
            # $formHtml += "<input type=""hidden"" name=""as_sitesearch"" value=""$siteSearchValue"">" # Another variant for Google
            $formHtml += "<div class=""control""><button class=""button is-info is-small mt-1"" type=""submit"">Go</button></div></form>"
        }
        "duckduckgo" {
            $formHtml = "<form class=""field has-addons"" method=""post"" action=""https://duckduckgo.com/"" target=""_blank"" style=""float:right;"">" # DDG often uses POST for site search from external forms
            $formHtml += "<div class=""control""><input class=""input is-small mt-1"" name=""q"" type=""text"" placeholder=""Search DDG..."" style=""width:$($Global:SearchBoxWidth)ch;""></div>"
            $formHtml += "<input name=""sites"" type=""hidden"" value=""$($Global:CmsUrl -replace 'https?://', '')"">" # DDG specific 'sites'
            $formHtml += "<div class=""control""><button class=""button is-info is-small mt-1"" type=""submit"">Go</button></div></form>"
        }
        "duckduckgo-official" { # Uses GET and their params
             $formHtml = "<form class=""field has-addons"" method=""get"" action=""https://duckduckgo.com/"" target=""_blank"" style=""float:right;"">"
             $formHtml += "<div class=""control""><input class=""input is-small mt-1"" name=""q"" type=""text"" placeholder=""Search DDG..."" style=""width:$($Global:SearchBoxWidth)ch;""></div>"
             # For DDG, the query 'q' can include site:domain.com or site:domain.com/path
             # $formHtml += "<input name=""sites"" type=""hidden"" value=""$($Global:CmsUrl -replace 'https?://', '')"">" # Not typically needed if 'site:' is in q
             $formHtml += "<div class=""control""><button class=""button is-info is-small mt-1"" type=""submit"">Go</button></div></form>"
             # User would type: my search term site:example.com/news
        }
        default {
            Write-Warning "Search box engine '$($Global:SearchBoxEngine)' is not recognized. No search box will be generated."
            return ""
        }
    }
    Write-Verbose "Generated search box HTML for engine '$($Global:SearchBoxEngine)'."
    return $formHtml
}

function Get-HistoryButtonHtml {
    [CmdletBinding()] param()
    Write-Verbose "Generating History button HTML."
    return "<a class=""$($Global:CssInfoButtonClass)"" href=""$($Global:ButtonHistoryUrl)""><img src=""images0/$($Global:ButtonHistoryIcon)"" width=""24"" height=""24"" title=""$($Global:ButtonHistoryTooltip)"" alt=""$($Global:ButtonHistoryTooltip)""/>&nbsp;$($Global:ButtonHistoryText)</a>" # Removed trailing &nbsp; as it's better handled by CSS margin/padding
}

function Get-TagsIndexButtonHtml {
    [CmdletBinding()] param()
    Write-Verbose "Generating Tags Index button HTML."
    return "<a class=""$($Global:CssInfoButtonClass)"" href=""$($Global:ButtonTagsindexUrl)""><img src=""images0/$($Global:ButtonTagsindexIcon)"" width=""24"" height=""24"" title=""$($Global:ButtonTagsindexTooltip)"" alt=""$($Global:ButtonTagsindexTooltip)""/>&nbsp;$($Global:ButtonTagsindexText)</a>"
}

function Get-RssButtonHtml {
    [CmdletBinding()] param()
    Write-Verbose "Generating RSS button HTML."
    return "<a class=""$($Global:CssInfoButtonClass)"" href=""$($Global:ButtonRssUrl)""><img src=""images0/$($Global:ButtonRssIcon)"" width=""24"" height=""24"" title=""$($Global:ButtonRssTooltip)"" alt=""$($Global:ButtonRssTooltip)""/>&nbsp;$($Global:ButtonRssText)</a>"
}


function Get-SpelunkerPageHeaderHtml {
    [CmdletBinding()]
    param()

    Write-Verbose "Generating main page header HTML..."

    # --- Bulma Classes (from shellcms_b create_includes) ---
    $cssStyleContainer = "columns is-multiline is-vcentered"
    $cssStyleBannerPictureContainer = "column is-narrow is-vcentered ml-3 pb-0"
    $cssStyleFigureParameters = "image is-128x128" # Or make this configurable if needed
    $cssStyleBannerTextContainer = "column is-narrow ml-3 pr-0 pb-0"
    $cssStyleTitleSize = "is-size-2" # For the main <h1> title
    $cssStyleButtonDiv = "column is-narrow pt-0 spelunker-button-bar" # Added custom class, pt-0 to align better

    # --- Start HTML Construction ---
    $htmlBuilder = New-Object System.Text.StringBuilder

    # Main container for banner and title
    [void]$htmlBuilder.Append("<div class=""$cssStyleContainer"">") # Outer columns div

    # Banner Picture Column
    if (-not [string]::IsNullOrWhiteSpace($Global:BannerPicture)) {
        [void]$htmlBuilder.Append("  <div class=""$cssStyleBannerPictureContainer"">")
        [void]$htmlBuilder.Append("    <figure class=""$cssStyleFigureParameters"">")
        # Path to banner picture needs to be relative to page; "images0/" is for top-level.
        # This will be adjusted later by Adjust-AssetPaths. For now, assume "images0/"
        [void]$htmlBuilder.Append("      <img src=""images0/$($Global:BannerPicture)"" alt=""Site Banner"" />")
        [void]$htmlBuilder.Append("    </figure>")
        [void]$htmlBuilder.Append("  </div>")
    }

    # Title and Description Column
    [void]$htmlBuilder.Append("  <div class=""$cssStyleBannerTextContainer"">")
    [void]$htmlBuilder.Append("    <h1 class=""title $cssStyleTitleSize""><strong>$($Global:SiteTitle)</strong></h1>")
    if (-not [string]::IsNullOrWhiteSpace($Global:SiteDescription)) {
        [void]$htmlBuilder.Append("    <p class=""subtitle"">$($Global:SiteDescription)</p>")
    }
    [void]$htmlBuilder.Append("  </div>")

    [void]$htmlBuilder.Append("</div>") # End of outer columns div for banner/title

    # Button Bar Div
    [void]$htmlBuilder.Append("<div class=""$cssStyleButtonDiv"">") # Using a simple div for buttons now

    # Permanent Buttons (Loop through ButtonPermanent1, 2, 3)
    foreach ($permButtonKeyConfig in @($Global:ButtonPermanent1, $Global:ButtonPermanent2, $Global:ButtonPermanent3)) {
        if (-not [string]::IsNullOrWhiteSpace($permButtonKeyConfig)) {
            $baseVarName = "Global:Button$($permButtonKeyConfig)"

            $buttonText = (Get-Variable -Name ($baseVarName + "Text") -ErrorAction SilentlyContinue).Value
            $buttonUrl = (Get-Variable -Name ($baseVarName + "Url") -ErrorAction SilentlyContinue).Value
            $buttonIcon = (Get-Variable -Name ($baseVarName + "Icon") -ErrorAction SilentlyContinue).Value
            $buttonTooltip = (Get-Variable -Name ($baseVarName + "Tooltip") -ErrorAction SilentlyContinue).Value
            $buttonClass = $Global:CssPermanentButtonClass

            if ($buttonText -and $buttonUrl -and $buttonIcon) {
                [void]$htmlBuilder.AppendFormat('  <a class="{0}" href="{1}" title="{2}"><img src="images0/{3}" width="24" height="24" alt="{4}" />&nbsp;{5}</a>',
                    $buttonClass, $buttonUrl, $buttonTooltip, $buttonIcon, $buttonText, $buttonText
                )
            } else {
                Write-Verbose "Skipping permanent button for key '$permButtonKeyConfig' due to missing configuration details (Text, Url, or Icon)."
            }
        }
    }

    # Placeholders for other buttons (these will be replaced later by other functions)
    [void]$htmlBuilder.Append("<!--SPELUNKER_SECONDBUTTON-->")
    [void]$htmlBuilder.Append("<!--SPELUNKER_THIRDBUTTON-->")
    [void]$htmlBuilder.Append("<!--SPELUNKER_FOURTHBUTTON-->")
    [void]$htmlBuilder.Append("<!--SPELUNKER_FIFTHBUTTON-->")
    [void]$htmlBuilder.Append("<!--SPELUNKER_SIXTHBUTTON-->")
    [void]$htmlBuilder.Append("<!--SPELUNKER_SEVENTHBUTTON-->")

    [void]$htmlBuilder.Append("</div><br />")

    Write-Verbose "Main page header HTML generated."
    return $htmlBuilder.ToString()
}


# Site Identity (Partially set by -Path, others are defaults or from future config file)
# $Global:SiteTitle is already set from $Path if specified, or default
# $Global:SiteAuthor is already set
$Global:SiteUrl = "http://adevjournal.info" # Example default, ideally from config
$Global:CmsUrl = "$($Global:SiteUrl)/news"   # Example default, ideally from config
$Global:SiteDescription = "A static html/css site generator powered by PowerShell" # Default

# Banner Picture
$Global:BannerPicture = "sit-svgrepo-com.svg" # Default

# Button CSS Styles
$Global:CssPermanentButtonClass = "button is-primary is-light"
$Global:CssInfoButtonClass = "button is-info is-light"

# Permanent Buttons Configuration (up to 3, names refer to detailed configs below)
$Global:ButtonPermanent1 = "sitehome"
$Global:ButtonPermanent2 = "contact"
$Global:ButtonPermanent3 = ""

# --- Detailed Button Configurations ---
# Site Home Button (corresponds to "sitehome")
$Global:ButtonSitehomeText = "site"
$Global:ButtonSitehomeUrl = "$($Global:SiteUrl)/" # Absolute URL
$Global:ButtonSitehomeIcon = "home-svgrepo-com.svg"
$Global:ButtonSitehomeTooltip = "Website homepage"

# Contact Button (corresponds to "contact")
$Global:ButtonContactText = "contact"
$Global:ButtonContactUrl = "http://somewhere.org/contact/" # Example absolute
$Global:ButtonContactIcon = "comment-svgrepo-com.svg"
$Global:ButtonContactTooltip = "Send email to site manager"

# Subhome Button / News (corresponds to "subhome" or "news")
# This button often points to the root of the current CMS instance (e.g., /news/index.html)
$Global:ButtonSubhomeText = "news"
$Global:ButtonSubhomeUrl = "index.html" # Relative to CmsUrl/ContentRoot
$Global:ButtonSubhomeIcon = "book-svgrepo-com.svg"
$Global:ButtonSubhomeTooltip = "News homepage (current section)"

# History Button (corresponds to "history")
$Global:ButtonHistoryText = "history"
$Global:ButtonHistoryUrl = "all_posts.html" # Relative path within ContentRoot
$Global:ButtonHistoryIcon = "layers-svgrepo-com.svg"
$Global:ButtonHistoryTooltip = "Posts history"

# Tags Index Button (corresponds to "tagsindex")
$Global:ButtonTagsindexText = "index"
$Global:ButtonTagsindexUrl = "all_tags.html" # Relative path within ContentRoot
$Global:ButtonTagsindexIcon = "paper-bag-svgrepo-com.svg"
$Global:ButtonTagsindexTooltip = "All categories"

# RSS Button (corresponds to "rss")
$Global:ButtonRssText = "rss"
$Global:ButtonRssUrl = "feed.rss" # Relative path within ContentRoot
$Global:ButtonRssIcon = "activity-svgrepo-com.svg"
$Global:ButtonRssTooltip = "RSS feed"

# Search Box Configuration
$Global:SearchBoxPages = "index post tags all_posts all_docs all_tags" # Space-delimited list
$Global:SearchBoxWidth = "40"
$Global:SearchBoxEngine = "google" # google, duckduckgo, duckduckgo-official

# Localization strings for links
$Global:TemplateArchiveIndexPage = "Back to the front page"


function Show-SpelunkerHelp {
    <#
    .SYNOPSIS
        Displays the help message for spelunker.ps1.
    .DESCRIPTION
        Shows detailed information about how to use the spelunker.ps1 script,
        including parameters, commands, and examples.
    #>
    param() # No parameters for the help function itself

    $helpText = @'
NAME
    spelunker.ps1 - A PowerShell script for generating a static blog/site,
                    mimicking features from shellcms_b.

SYNOPSIS
    ./spelunker.ps1 -Command <command_name> [-Path <content_root_path>]
                    [-PostHtmRawPathParameter <path_to_post.htmraw>]
                    [-EditHtmRawPathParameter <path_to_edit.htmraw>]
                    [-Interactive]
                    [-Verbose]
                    [-Help]

DESCRIPTION
    Spelunker is a static site generator written in PowerShell. It processes
    .htmraw files (HTML content snippets), applies templates, and generates
    a full static HTML website, including posts and index pages.

PARAMETERS
    -Command <string>
        Specifies the action to perform.
        Aliases: None

    -Path <string>
        The root directory of your content (e.g., "www/news" or "myblog").
        Defaults to "www/news" relative to the script's location if not specified.
        This path is used as the ContentRoot for finding templates, posts,
        and generating output.
        Aliases: ContentRootPath

    -PostHtmRawPathParameter <string>
        The path to the .htmraw file for the 'post' command.
        If the file doesn't exist, it will be created from a skeleton.
        Relative paths are resolved from the ContentRoot.
        Aliases: PostFilePath

    -EditHtmRawPathParameter <string>
        The path to the .htmraw file for the 'edit' command.
        Relative paths are resolved from the ContentRoot.
        Aliases: EditFilePath

    -Interactive [<switch>]
        Runs the script in interactive mode, prompting for missing parameters
        and choices via a Text User Interface (TUI).
        Aliases: None

    -Verbose [<switch>]
        Provides detailed output of the script's operations.
        Aliases: vb

    -Help [<switch>]
        Displays this help message and exits.
        Aliases: h, ?

AVAILABLE COMMANDS
    post
        Creates a new post from skeleton if the .htmraw file specified by
        -PostHtmRawPathParameter doesn't exist, or processes an existing one.
        Generates the corresponding .html file and updates all index pages.
        In -Interactive mode, prompts for tags and post-save actions for new posts.

    edit
        Opens an existing .htmraw file (specified by -EditHtmRawPathParameter)
        in a detected text editor. Does not generate HTML or update indexes.
        In -Interactive mode, if no path is specified, it lists files for selection.

    rebuild
        Regenerates all .html post files from their .htmraw sources within the
        ContentRoot. Updates all index pages (main, all_posts, all_tags, and
        individual tag pages).

    list (Placeholder - To be implemented)
        Lists all published posts. (Currently not implemented in TUI/direct command)

    tags (Placeholder - To be implemented)
        Lists all unique tags. (Currently not implemented in TUI/direct command, though tag pages are generated)

EXAMPLES
    ./spelunker.ps1 -Command rebuild -Path "my_site_content"
        Rebuilds the site located in "my_site_content".

    ./spelunker.ps1 -Command post -PostHtmRawPathParameter "posts/my-new-article.htmraw" -Verbose
        Creates or processes "posts/my-new-article.htmraw" and shows detailed output.

    ./spelunker.ps1 -Interactive
        Starts the script in interactive mode, prompting for path and command.

    ./spelunker.ps1 -h
        Displays this help message.

NOTES
    - Paths for -PostHtmRawPathParameter and -EditHtmRawPathParameter are generally
      resolved relative to the -Path (ContentRoot) if not absolute.
    - Editor for 'edit' command and new 'post' files is detected automatically
      or can be set via the $Global:PreferredEditor variable in the script.
'@ # End of here-string

    Write-Host $helpText
}

# Set your preferred editor here, e.g., "code.exe", "C:\Program Files\Notepad++\notepad++.exe", "subl.exe"
# If $null, the script will search for common editors.
$Global:PreferredEditor = $null
$Global:NumberOfIndexArticles = 10 # Default, can be overridden by config file later
$Global:SiteTitle = "My PowerShell Blog" # Default, can be overridden
$Global:SiteAuthor = "PowerShell User" # Default, can be overridden

# Initialize global paths based on the -Path parameter (or its default)
Set-GlobalPathVariables -BaseContentPathFromParam $Path


# --- Interactive Mode Logic (TUI for initial command/path) ---
if ($Global:IsInteractiveMode) {
    Write-Verbose "Interactive mode detected."

    # 1. Prompt for Content Path if not provided via -Path
    if (-not $PSBoundParameters.ContainsKey('Path')) {
        Write-Host "Current Content Root: $ContentRoot"
        $inputPath = Read-Host -Prompt "Enter new path for content root, or press Enter to keep current"
        if (-not [string]::IsNullOrWhiteSpace($inputPath)) {
            if (Test-Path -Path $inputPath -IsValid) { # Basic validation, more robust check in Set-GlobalPathVariables
                Write-Verbose "User entered new path: $inputPath. Re-initializing global paths."
                $Path = $inputPath # Update $Path from param block to reflect user's choice for consistency
                Set-GlobalPathVariables -BaseContentPathFromParam $Path # Re-initialize all paths
            } else {
                Write-Warning "The path '$inputPath' seems invalid or inaccessible. Keeping current ContentRoot: $ContentRoot"
            }
        }
    }

    # 2. Prompt for Command if not provided via -Command
    if ([string]::IsNullOrWhiteSpace($Command)) {
        $availableCommands = @(
            [pscustomobject]@{ Name = "post";    Description = "Create a new post or process an existing .htmraw file." }
            [pscustomobject]@{ Name = "edit";    Description = "Open an existing .htmraw file in an editor." }
            [pscustomobject]@{ Name = "rebuild"; Description = "Rebuild all HTML files from .htmraw sources and update all indexes." }
            # Placeholders for future commands:
            # [pscustomobject]@{ Name = "list";    Description = "List all published posts." }
            # [pscustomobject]@{ Name = "tags";    Description = "List all tags." }
            [pscustomobject]@{ Name = "exit";    Description = "Exit Spelunker." }
        )

        Write-Host "`nPlease select a command to execute:" -ForegroundColor Yellow
        # Attempt Out-GridView first, fallback to Read-Host if it fails (e.g. non-interactive console)
        try {
            $selectedCommandEntry = $availableCommands | Out-GridView -Title "Select Spelunker Command" -PassThru -ErrorAction Stop
            if ($selectedCommandEntry) {
                $Command = $selectedCommandEntry.Name
                Write-Verbose "User selected command via Out-GridView: $Command"
            } else {
                Write-Warning "No command selected via Out-GridView."
                # Allow fallback to Read-Host or exit
            }
        } catch {
            Write-Verbose "Out-GridView failed or not available, falling back to Read-Host selection. Error: $($_.Exception.Message)"
            for ($i = 0; $i -lt $availableCommands.Count; $i++) {
                Write-Host ("{0,2}. {1,-10} - {2}" -f ($i + 1), $availableCommands[$i].Name, $availableCommands[$i].Description)
            }
            $choice = Read-Host -Prompt "Enter command number"
            if ($choice -match '^\d+$' -and [int]$choice -ge 1 -and [int]$choice -le $availableCommands.Count) {
                $Command = $availableCommands[[int]$choice - 1].Name
                Write-Verbose "User selected command via Read-Host: $Command"
            } else {
                Write-Warning "Invalid selection '$choice'."
                # $Command remains empty or previously set
            }
        }

        if ([string]::IsNullOrWhiteSpace($Command) -or $Command -eq "exit") {
            Write-Host "No command selected or 'exit' chosen. Exiting Spelunker."
            exit
        }
    }
}

# --- Main Command Switch ---
Write-Verbose "Executing command: $Command"
# Placeholder functions
function Invoke-Rebuild {
    Write-Host "Starting Invoke-Rebuild. ContentRoot: $ContentRoot (Full: $((Resolve-Path $ContentRoot).Path))"

    Write-Host "Starting Invoke-Rebuild. ContentRoot: $ContentRoot (Full: $((Resolve-Path $ContentRoot -ErrorAction SilentlyContinue).Path))" # Added SilentlyContinue
    Write-Verbose "Using ContentRoot: $ContentRoot, TemplatesDir: $TemplatesDir"

    # Ensure ContentRoot actually exists before trying to Get-ChildItem
    if (-not (Test-Path -Path $ContentRoot -PathType Container)) {
        Write-Error "ContentRoot directory not found: '$ContentRoot'. Please ensure the -Path parameter is correct and the directory exists."
        return
    }
    Write-Verbose "ContentRoot directory confirmed: $ContentRoot"

    $sourceFiles = Get-ChildItem -Path $ContentRoot -Filter *.htmraw -Recurse -ErrorAction SilentlyContinue
    $processedCount = 0
    $errorCount = 0
    $generatedHtmlFiles = 0 # Specific counter for successfully generated HTML

    if ($null -eq $sourceFiles -or $sourceFiles.Count -eq 0) {
        Write-Warning "No .htmraw files found in $ContentRoot to rebuild."
        # Still proceed to update indexes, as they might need to be generated (e.g., as empty)
    } else {
        Write-Host "Found $($sourceFiles.Count) .htmraw files to process."
    }

    # Get full path of ContentRoot once to ensure accurate relative path calculation
    $fullContentRootPath = (Resolve-Path $ContentRoot).Path

    foreach ($sourceFile in $sourceFiles) {
        try {
            Write-Verbose "Processing source file: $($sourceFile.FullName)"
            $fullSourcePath = $sourceFile.FullName

            $relativePath = $fullSourcePath.Substring($fullContentRootPath.Length)
            if ($relativePath.Length -gt 0 -and -not ($relativePath.StartsWith('/') -or $relativePath.StartsWith('\'))) {
                $relativePath = [System.IO.Path]::DirectorySeparatorChar + $relativePath
            }
            $relativeDir = Split-Path -Path $relativePath
            $outputFileName = [System.IO.Path]::GetFileNameWithoutExtension($sourceFile.Name) + ".html"
            $finalOutputDir = Join-Path -Path $ContentRoot -ChildPath $relativeDir
            $outputFilePath = Join-Path -Path $finalOutputDir -ChildPath $outputFileName
            Write-Verbose "Output target for $($sourceFile.Name) is $outputFilePath"

            if (-not (Test-Path $finalOutputDir -PathType Container)) {
                Write-Verbose "Output directory $finalOutputDir does not exist, creating..."
                New-Item -ItemType Directory -Path $finalOutputDir -Force -ErrorAction Stop | Out-Null
                Write-Host "Created directory: $finalOutputDir"
            }

            $timestamp = (Get-Item $sourceFile.FullName).LastWriteTime

            # New-BlogPostHtml handles its own success/error messages
            New-BlogPostHtml -SourceFilePath $sourceFile.FullName -OutputFilePath $outputFilePath -Timestamp $timestamp

            # Basic check if HTML was generated
            if (Test-Path $outputFilePath -PathType Leaf) {
                $generatedHtmlFiles++
            }
            $processedCount++
        } catch {
            # Catching exceptions from New-Item or other critical errors in the loop itself
            Write-Error "Critical error encountered while processing file $($sourceFile.FullName): $($_.Exception.Message)"
            $errorCount++
        }
    }

    Write-Host "--- Rebuild Summary ---"
    Write-Host "Total .htmraw files found: $($sourceFiles.Count)"
    Write-Host "Files processed for HTML generation: $processedCount"
    Write-Host "HTML files successfully generated: $generatedHtmlFiles"
    Write-Host "Errors during HTML generation: $errorCount"

    Write-Verbose "Starting index updates after processing posts..."
    Update-MainIndex
    Update-AllPostsIndex
    Update-TagsIndex
    Write-Host "--- Indexing Complete ---"
    Write-Host "Rebuild process finished."
}

# Function to open a specified file in an editor
function Invoke-Edit {
    param(
        # Parameter is no longer mandatory here; logic below will handle interactive selection if not provided.
        [string]$EditFilePathParameter
    )

    $ResolvedEditPath = $null

    if (-not ([string]::IsNullOrWhiteSpace($EditFilePathParameter))) {
        Write-Verbose "Invoke-Edit started with provided parameter: $EditFilePathParameter"
        $ResolvedEditPath = $EditFilePathParameter
        if (-not ([System.IO.Path]::IsPathRooted($ResolvedEditPath))) {
            Write-Verbose "Provided path '$ResolvedEditPath' is relative. Resolving against ContentRoot: $Global:ContentRoot"
            $ResolvedEditPath = Join-Path -Path $Global:ContentRoot -ChildPath $ResolvedEditPath
        }
        try {
            $ResolvedEditPath = (Resolve-Path -LiteralPath $ResolvedEditPath -ErrorAction Stop).Path
            Write-Verbose "Path resolved to: $ResolvedEditPath"
            if (-not (Test-Path -LiteralPath $ResolvedEditPath -PathType Leaf)) {
                Write-Error "File not found or is not a file at the provided path: $ResolvedEditPath"
                return
            }
        } catch {
            Write-Error "Error resolving or accessing provided file path '$EditFilePathParameter': $($_.Exception.Message)"
            return
        }
    } elseif ($Global:IsInteractiveMode) {
        Write-Verbose "Invoke-Edit started in interactive mode without a pre-defined file path."
        Write-Host "Please select an .htmraw file to edit:" -ForegroundColor Yellow

        $availableFiles = Get-ChildItem -Path $Global:ContentRoot -Filter *.htmraw -Recurse -File -ErrorAction SilentlyContinue |
            Select-Object FullName, @{Name="RelativePath"; Expression={$_.FullName.Substring($Global:ContentRoot.Length).TrimStart('\/')}}, Name, LastWriteTime, DirectoryName |
            Sort-Object RelativePath

        if ($null -eq $availableFiles -or $availableFiles.Count -eq 0) {
            Write-Warning "No .htmraw files found in '$($Global:ContentRoot)' or its subdirectories."
            return
        }

        $selectedFile = $null
        try {
            $selectedFile = $availableFiles | Out-GridView -Title "Select .htmraw File to Edit" -PassThru -ErrorAction Stop
        } catch {
            Write-Warning "Out-GridView is not available or failed. Error: $($_.Exception.Message)"
            # Fallback to a simpler list if Out-GridView fails (though less ideal for many files)
            Write-Host "Available files to edit:"
            for($i=0; $i -lt $availableFiles.Count; $i++) {
                Write-Host ("{0,3}: {1}" -f ($i+1), $availableFiles[$i].RelativePath)
            }
            $choice = Read-Host -Prompt "Enter number of file to edit"
            if ($choice -match '^\d+$' -and [int]$choice -ge 1 -and [int]$choice -le $availableFiles.Count) {
                $selectedFile = $availableFiles[[int]$choice - 1]
            }
        }

        if ($null -eq $selectedFile) {
            Write-Warning "No file selected for editing."
            return
        }
        $ResolvedEditPath = $selectedFile.FullName # Use FullName as it's already an absolute path
        Write-Verbose "User selected file: $ResolvedEditPath"
    } else {
        Write-Error "The 'edit' command requires a file path to be specified via -EditHtmRawPathParameter (or -EditFilePath) when not in interactive mode."
        return
    }

    Write-Host "Attempting to edit file: $ResolvedEditPath"

    # Editor Launch (common logic for both parameter-provided and interactively selected path)
    $editorCommand = Get-EditorCommand
    if (-not [string]::IsNullOrEmpty($editorCommand)) {
        Write-Verbose "Attempting to open '$ResolvedEditPath' with editor: $editorCommand"
        try {
            Start-Process -FilePath $editorCommand -ArgumentList $ResolvedEditPath -ErrorAction Stop
            $editorExeName = ($editorCommand -split '[\\/]')[-1]
            Write-Host "Launched editor '$editorExeName' for '$ResolvedEditPath'."
        }
        catch {
            Write-Warning "Failed to launch editor '$editorCommand' for '$ResolvedEditPath'. Error: $($_.Exception.Message)"
        }
    }
    else {
        # Get-EditorCommand already issues a Write-Warning if no editor is found.
        Write-Host "No suitable editor found or configured to open '$ResolvedEditPath'. Please open it manually."
    }
}

# Function to determine the editor command to use
function Get-EditorCommand {
    Write-Verbose "Attempting to determine editor command..."

    # 1. Check Preferred Editor
    if (-not ([string]::IsNullOrWhiteSpace($Global:PreferredEditor))) {
        Write-Verbose "Checking for preferred editor: '$Global:PreferredEditor'"
        $foundCommand = Get-Command -Name $Global:PreferredEditor -ErrorAction SilentlyContinue
        if ($null -ne $foundCommand) {
            Write-Verbose "Using preferred editor: $($foundCommand.Source)"
            return $foundCommand.Source
        } else {
            Write-Verbose "Preferred editor '$Global:PreferredEditor' not found in PATH."
        }
    } else {
        Write-Verbose "No preferred editor set in `$Global:PreferredEditor."
    }

    # 2. Check Common Editors
    Write-Verbose "Checking common editors."
    $commonEditors = @("code.exe", "code-insiders.exe", "notepad++.exe", "subl.exe", "atom.exe", "geany.exe", "notepad.exe")
    # Added code-insiders based on common usage.

    foreach ($editorName in $commonEditors) {
        Write-Verbose "Checking for editor: $editorName"
        $foundCommand = Get-Command -Name $editorName -ErrorAction SilentlyContinue
        if ($null -ne $foundCommand) {
            Write-Verbose "Found common editor: $($foundCommand.Source)"
            return $foundCommand.Source
        }
    }

    # 3. Fallback/Not Found
    Write-Warning "No suitable editor found after checking preferred and common list. Please set `$Global:PreferredEditor or install a common editor."
    return $null
}

# Function to update the main index.html page
function Update-MainIndex {
    Write-Host "Updating main index page: $IndexFile"
    Write-Verbose "Global IndexFile path: $IndexFile, NumberOfIndexArticles: $NumberOfIndexArticles"

    # 1. Find relevant .htmraw source files
    Write-Verbose "Scanning $ContentRoot for .htmraw files to build main index."
    $allHtmRawFiles = Get-ChildItem -Path $ContentRoot -Filter *.htmraw -Recurse -ErrorAction SilentlyContinue
    if ($null -eq $allHtmRawFiles -or $allHtmRawFiles.Count -eq 0) {
        Write-Warning "No .htmraw files found in $ContentRoot. Main index will be empty or reflect no posts."
        # Allow to proceed to generate an empty index if that's the case
    }

    $postObjects = @()
    # Resolve path once for all substring operations
    $resolvedFullContentRootPath = (Resolve-Path $ContentRoot -ErrorAction SilentlyContinue).Path
    if (-not $resolvedFullContentRootPath) {
        Write-Error "Cannot resolve ContentRoot full path: $ContentRoot. Aborting main index update."
        return
    }

    foreach ($htmrawFile in $allHtmRawFiles) {
        Write-Verbose "Processing $($htmrawFile.FullName) for main index."
        if ($htmrawFile.FullName.StartsWith((Resolve-Path $TemplatesDir -ErrorAction SilentlyContinue).Path)) { # Added ErrorAction
            Write-Verbose "Skipping file in TemplatesDir: $($htmrawFile.FullName)"
            continue
        }

        $parsedData = Parse-HtmRawContent -RawContent (Get-HtmRawSourceFile -FilePath $htmrawFile.FullName)
        if (-not $parsedData) { # Parse-HtmRawContent itself logs, this is a fallback.
            Write-Warning "Could not parse $($htmrawFile.FullName) or it returned no data, skipping for index."
            continue
        }

        $relativeHtmRawPath = $htmrawFile.FullName.Substring($resolvedFullContentRootPath.Length)
        if ($relativeHtmRawPath.StartsWith('/') -or $relativeHtmRawPath.StartsWith('\')) {
            $relativeHtmRawPath = $relativeHtmRawPath.Substring(1)
        }
        $htmlLink = ($relativeHtmRawPath -replace [regex]::Escape(".htmraw"), ".html") -replace '\\', '/'


        $timestamp = $htmrawFile.LastWriteTime
        $htmlFilePath = Join-Path -Path (Split-Path -Path $htmrawFile.FullName) -ChildPath ([System.IO.Path]::GetFileNameWithoutExtension($htmrawFile.Name) + ".html")
        Write-Verbose "Source: $($htmrawFile.Name), HTML Link: $htmlLink, Timestamp: $timestamp, Expected HTML Path: $htmlFilePath"

        $summary = "Summary not available."
        if (Test-Path $htmlFilePath -PathType Leaf) {
            Write-Verbose "Extracting summary from $htmlFilePath"
            $htmlFileContent = Get-HtmRawSourceFile -FilePath $htmlFilePath
            if ($htmlFileContent) { # Check if content was actually read
                $bodyMatch = $htmlFileContent | Select-String -Pattern '(?s)<body>(.*?)</body>'
                $postBodyHtml = if ($bodyMatch) { $bodyMatch.Matches[0].Groups[1].Value } else { $htmlFileContent }

                if ($postBodyHtml) {
                    $splitByHr = $postBodyHtml -split '<\s*hr\s*/?\s*>', 2
                    $contentBeforeHr = $splitByHr[0]
                    $summaryText = ConvertFrom-HtmlToText -HtmlContent $contentBeforeHr
                    $summary = if ($summaryText.Length -gt 300) {
                        $summaryText.Substring(0, 300).Trim() + "..."
                    } else {
                        $summaryText.Trim()
                    }
                    Write-Verbose "Summary for $($htmrawFile.Name): '$($summary.Substring(0, [System.Math]::Min($summary.Length, 50)))...'" # Log a snippet
                }
            } else {
                Write-Warning "Could not read HTML file $htmlFilePath for summary extraction (it might be empty or unreadable)."
            }
        } else {
            Write-Warning "Generated HTML file $htmlFilePath not found for summary extraction. Post $($htmrawFile.Name) might not have been generated yet, or path is incorrect."
        }

        $postObjects += [PSCustomObject]@{
            Title           = $parsedData.Title
            HtmlRelativePath = $htmlLink
            Timestamp       = $timestamp
            Summary         = $summary
            SourceHtmRawPath = $htmrawFile.FullName
        }
    }
    Write-Verbose "Finished collecting post data for main index. $($postObjects.Count) posts considered."

    # 2. Sort Posts (newest first) and select top N
    Write-Verbose "Sorting posts and selecting top $NumberOfIndexArticles for main index."
    $sortedPosts = $postObjects | Sort-Object -Property Timestamp -Descending | Select-Object -First $NumberOfIndexArticles

    # 3. Generate HTML content for the index
    $indexContentBuilder = New-Object System.Text.StringBuilder
    if ($sortedPosts.Count -gt 0) {
        Write-Verbose "Generating list entries for main index page with $($sortedPosts.Count) posts."
        foreach ($post in $sortedPosts) {
            [void]$indexContentBuilder.AppendLine('<div class="post-entry">')
            [void]$indexContentBuilder.AppendLine("    <h3><a href=""$($post.HtmlRelativePath)"">$($post.Title)</a></h3>")
            [void]$indexContentBuilder.AppendLine("    <p class=""summary"">$($post.Summary)</p>")
            [void]$indexContentBuilder.AppendLine("    <p class=""date"">$($post.Timestamp.ToString('yyyy-MM-dd HH:mm'))</p>")
            [void]$indexContentBuilder.AppendLine('</div>')
            [void]$indexContentBuilder.AppendLine('<hr />')
        }
    } else {
        Write-Verbose "No posts to list on main index page."
        [void]$indexContentBuilder.AppendLine("<p>No posts yet. Stay tuned!</p>")
    }

    # 4. Construct Full Index Page
    Write-Verbose "Constructing full HTML for $IndexFile."
    # Get template contents
    $cmsHeaderContent = Get-TemplateContent -TemplatePath $Global:HeaderTemplate # Renamed to avoid clash
    $cmsFooterContent = Get-TemplateContent -TemplatePath $Global:FooterTemplate # Renamed
    $cmsBeginContent = Get-TemplateContent -TemplatePath $Global:BeginTemplate   # Renamed
    $cmsEndContent = Get-TemplateContent -TemplatePath $Global:EndTemplate     # Renamed

    if ($null -eq $cmsHeaderContent -or $null -eq $cmsFooterContent -or $null -eq $cmsBeginContent -or $null -eq $cmsEndContent) {
        Write-Error "One or more base template files ($($Global:HeaderTemplate), $($Global:FooterTemplate), $($Global:BeginTemplate), $($Global:EndTemplate)) could not be read or are empty for index generation. Aborting $IndexFile generation."
        return
    }

    # Inject specific page title into the <head> from cms_header.txt
    $headerWithPageTitle = $cmsHeaderContent -replace '</head>', "<title>$($Global:SiteTitle) - Home</title></head>"

    # Get the dynamic Spelunker header (banner, site title, permanent buttons)
    $baseSpelunkerHeaderHtml = Get-SpelunkerPageHeaderHtml # Base header with placeholders

    # Inject page-specific buttons and search box for Update-MainIndex (index.html)
    $finalHeaderHtml = $baseSpelunkerHeaderHtml

    # Search Box
    if ($Global:SearchBoxPages -match "index") { # Check if "index" is in SearchBoxPages
        $searchBoxHtml = Get-SearchBoxHtml
        $finalHeaderHtml = $finalHeaderHtml.Replace("<!--SPELUNKER_SEVENTHBUTTON-->", $searchBoxHtml)
    }

    # Page specific buttons for main index
    $historyButtonHtml = Get-HistoryButtonHtml
    $tagsIndexButtonHtml = Get-TagsIndexButtonHtml
    $rssButtonHtml = Get-RssButtonHtml

    $finalHeaderHtml = $finalHeaderHtml.Replace("<!--SPELUNKER_THIRDBUTTON-->", $historyButtonHtml)
    $finalHeaderHtml = $finalHeaderHtml.Replace("<!--SPELUNKER_FOURTHBUTTON-->", $tagsIndexButtonHtml)
    $finalHeaderHtml = $finalHeaderHtml.Replace("<!--SPELUNKER_FIFTHBUTTON-->", $rssButtonHtml)

    # Clear any remaining button placeholders
    $finalHeaderHtml = $finalHeaderHtml -replace "<!--SPELUNKER_.*?BUTTON-->", ""

    # Assemble the full page
    $fullIndexHtml = New-Object System.Text.StringBuilder
    [void]$fullIndexHtml.Append($headerWithPageTitle)       # Content from cms_header.txt (Doctype, html, head with specific title, body tag)
    [void]$fullIndexHtml.Append($finalHeaderHtml)           # Spelunker's dynamic header, now with page-specific buttons/search
    [void]$fullIndexHtml.Append($cmsBeginContent)           # Content from cms_begin.txt (e.g., opens main columns/container)
    [void]$fullIndexHtml.Append($indexContentBuilder.ToString()) # The actual list of post entries for the index
    [void]$fullIndexHtml.Append($cmsEndContent)             # Content from cms_end.txt (e.g., closes main columns/container)
    [void]$fullIndexHtml.Append($cmsFooterContent)          # Content from cms_footer.txt (e.g., footer iframe, closing body/html tags)

    try {
        $pageDepth = Determine-PageDepth -PagePath $IndexFile -BaseSitePath $Global:ContentRoot
        $finalHtmlContent = Adjust-AssetPaths -HtmlContentString $fullIndexHtml.ToString() -PageDepth $pageDepth
        Set-Content -Path $IndexFile -Value $finalHtmlContent -Force -ErrorAction Stop
        Write-Host "Main index page updated: $IndexFile"
    } catch {
        Write-Error "Failed to write main index page to $IndexFile: $($_.Exception.Message)"
    }
}

function Invoke-Post {
    param(
        [Parameter(Mandatory=$true)]
        [string]$PostHtmRawPathParameter
    )
    Write-Verbose "Invoke-Post started for parameter: $PostHtmRawPathParameter"

    # 1. Path Resolution
    $ResolvedPostHtmRawPath = $PostHtmRawPathParameter
    if (-not ([System.IO.Path]::IsPathRooted($ResolvedPostHtmRawPath))) {
        Write-Verbose "Provided path '$ResolvedPostHtmRawPath' is relative. Resolving against ContentRoot: $ContentRoot"
        $ResolvedPostHtmRawPath = Join-Path -Path $ContentRoot -ChildPath $ResolvedPostHtmRawPath
    }

    # Attempt to get full path, which also helps normalize it
    try {
        # Resolve-Path can error if the path doesn't exist, even parts of it.
        # For new files, we need to construct the full path carefully.
        if (Test-Path $ResolvedPostHtmRawPath) {
            $ResolvedPostHtmRawPath = (Resolve-Path $ResolvedPostHtmRawPath -ErrorAction Stop).Path
            Write-Verbose "Path exists and resolved to: $ResolvedPostHtmRawPath"
        } else {
            # Path doesn't exist, construct full path for potential creation
            # GetFullPath can resolve '..' etc. Needs a base if $ResolvedPostHtmRawPath might still be relative
            $baseForGetFullPath = $PSScriptRoot
            if ([System.IO.Path]::IsPathRooted($ContentRoot)) { $baseForGetFullPath = $ContentRoot }
            elseif(Test-Path (Join-Path $PSScriptRoot $ContentRoot)) { $baseForGetFullPath = (Resolve-Path (Join-Path $PSScriptRoot $ContentRoot)).Path}


            if (-not ([System.IO.Path]::IsPathRooted($ResolvedPostHtmRawPath))) {
                 # If still not rooted, join with our best guess for a base path.
                 $ResolvedPostHtmRawPath = Join-Path -Path $baseForGetFullPath -ChildPath $ResolvedPostHtmRawPath
            }
            $ResolvedPostHtmRawPath = [System.IO.Path]::GetFullPath($ResolvedPostHtmRawPath)
            Write-Verbose "Path does not exist yet, constructed full path: $ResolvedPostHtmRawPath"
        }
    } catch {
        Write-Error "Error resolving path '$PostHtmRawPathParameter': $($_.Exception.Message)"
        return
    }

    Write-Host "Effective post source file target: $ResolvedPostHtmRawPath"

    # 2. File Existence Check and Skeleton Copy
    $newFileCreated = $false # Flag to track if we created the file in this run
    if (-not (Test-Path $ResolvedPostHtmRawPath -PathType Leaf)) {
        Write-Host "Source file '$ResolvedPostHtmRawPath' does not exist. Attempting to create new post from skeleton..."
        $TargetDirectory = Split-Path -Path $ResolvedPostHtmRawPath
        if (-not (Test-Path $TargetDirectory -PathType Container)) {
            Write-Verbose "Target directory '$TargetDirectory' does not exist. Attempting to create."
            try {
                New-Item -ItemType Directory -Path $TargetDirectory -Force -ErrorAction Stop | Out-Null
                Write-Host "Created directory: $TargetDirectory"
            } catch {
                Write-Error "Failed to create directory '$TargetDirectory': $($_.Exception.Message)"
                return
            }
        }
        try {
            $SkeletonContent = Get-TemplateContent -TemplatePath $SkeletonTemplate
            if ($null -eq $SkeletonContent) { # Check if skeleton content itself is null
                Write-Error "Skeleton template ($SkeletonTemplate) content is empty or could not be read. Cannot create new post from skeleton."
                return
            }
            Set-Content -Path $ResolvedPostHtmRawPath -Value $SkeletonContent -Force -ErrorAction Stop
            Write-Host "New post created from skeleton: $ResolvedPostHtmRawPath"
            $newFileCreated = $true

            # Interactive Tag Input for new posts
            if ($Global:IsInteractiveMode) { # This if block is for tags
                Write-Verbose "Interactive mode: Prompting for tags for new post $ResolvedPostHtmRawPath"

                # Gather existing tags to suggest
                $allTagsFromAllPosts = [System.Collections.Generic.List[string]]::new()
                $tempAllHtmRawFiles = Get-ChildItem -Path $Global:ContentRoot -Filter *.htmraw -Recurse -ErrorAction SilentlyContinue
                foreach ($tempFileInScan in $tempAllHtmRawFiles) {
                    if ($tempFileInScan.FullName -ne $ResolvedPostHtmRawPath -and -not $tempFileInScan.FullName.StartsWith((Resolve-Path $Global:TemplatesDir -ErrorAction SilentlyContinue).Path)) {
                        $tempParsed = Parse-HtmRawContent -RawContent (Get-HtmRawSourceFile -FilePath $tempFileInScan.FullName)
                        if ($null -ne $tempParsed -and $null -ne $tempParsed.Tags) {
                            $tempParsed.Tags | ForEach-Object { $allTagsFromAllPosts.Add($_) }
                        }
                    }
                }
                $existingUniqueTags = $allTagsFromAllPosts | Sort-Object -Unique

                $selectedExistingTags = @()
                if ($existingUniqueTags.Count -gt 0) {
                    Write-Host "`nSelect existing tags (optional). Press OK for selections, Cancel to skip." -ForegroundColor Yellow
                    # Out-GridView can be finicky in some terminals / ISE, but is best effort.
                    try {
                        $selectedExistingTags = $existingUniqueTags | Out-GridView -Title "Select Existing Tags for '$($ResolvedPostHtmRawPath | Split-Path -Leaf)'" -PassThru -ErrorAction Stop
                        if ($null -eq $selectedExistingTags) { $selectedExistingTags = @() }
                        Write-Verbose "User selected existing tags via Out-GridView: $($selectedExistingTags -join ', ')"
                    } catch {
                         Write-Warning "Out-GridView for existing tag selection failed or was skipped. You can enter all tags manually. Error: $($_.Exception.Message)"
                         # Display manually if Out-GridView fails
                         Write-Host "Available existing tags:"
                         $existingUniqueTags | ForEach-Object { Write-Host "- $_" }
                         $tagsToSelectFromList = Read-Host -Prompt "Enter existing tags to use from the list above, separated by commas (or press Enter to skip)"
                         if (-not [string]::IsNullOrWhiteSpace($tagsToSelectFromList)) {
                             $selectedExistingTags = $tagsToSelectFromList.Split(',') | ForEach-Object { $_.Trim() } | Where-Object { $existingUniqueTags -contains $_ }
                         }
                    }
                } else {
                    Write-Verbose "No existing tags found to suggest."
                }

                $newTagsString = Read-Host -Prompt "Enter any NEW tags, separated by commas (optional)"
                $newTags = @()
                if (-not [string]::IsNullOrWhiteSpace($newTagsString)) {
                    $newTags = $newTagsString.Split(',') | ForEach-Object { $_.Trim() } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }
                }
                Write-Verbose "User entered new tags: $($newTags -join ', ')"

                $finalTags = ($selectedExistingTags + $newTags) | Sort-Object -Unique | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }

                if ($finalTags.Count -gt 0) {
                    Write-Verbose "Final combined tags: $($finalTags -join ', ')"
                    try {
                        $fileContent = Get-Content -Raw -Path $ResolvedPostHtmRawPath -ErrorAction Stop
                        # Regex to find <!--RawTags: followed by anything except -->, then -->
                        # This handles cases where tags might be empty or have various characters.
                        $updatedContent = $fileContent -replace '<!--RawTags:.*?-->', "<!--RawTags:$($finalTags -join ',')-->"
                        Set-Content -Path $ResolvedPostHtmRawPath -Value $updatedContent -Force -ErrorAction Stop
                        Write-Host "Updated tags in '$ResolvedPostHtmRawPath' to: $($finalTags -join ', ')" -ForegroundColor Green
                    } catch {
                        Write-Error "Failed to update tags in '$ResolvedPostHtmRawPath': $($_.Exception.Message)"
                    }
                } else {
                    # If skeleton had default tags and user removed them all, this path might be taken.
                    # Or if user provided no tags and selected none.
                    # We might want to ensure the RawTags line is still present but empty, e.g. <!--RawTags:-->
                    Write-Verbose "No final tags specified. Default tags from skeleton (if any) will be used or tags will be empty."
                    # Optionally, ensure the line is at least <!--RawTags:-->
                    try {
                        $fileContent = Get-Content -Raw -Path $ResolvedPostHtmRawPath -ErrorAction Stop
                        if ($fileContent -notmatch '<!--RawTags:.*?-->') {
                             # If the line is somehow missing, add it. This is defensive.
                             # For simplicity now, assuming skeleton always provides it.
                        } else {
                             # If user wants no tags, ensure the line is empty of tags
                             $updatedContent = $fileContent -replace '<!--RawTags:.*?-->', "<!--RawTags:-->"
                             if ($updatedContent -ne $fileContent) {
                                Set-Content -Path $ResolvedPostHtmRawPath -Value $updatedContent -Force -ErrorAction Stop
                                Write-Host "Cleared default tags in '$ResolvedPostHtmRawPath' as per user input." -ForegroundColor Green
                             }
                        }
                    } catch {
                         Write-Error "Failed to clear/verify tags in '$ResolvedPostHtmRawPath': $($_.Exception.Message)"
                    }
                }
            } # End if ($Global:IsInteractiveMode)

            # Launch editor for the new post
            $editorCommand = Get-EditorCommand
            if (-not [string]::IsNullOrEmpty($editorCommand)) {
                Write-Verbose "Attempting to open '$ResolvedPostHtmRawPath' with editor: $editorCommand"
                try {
                    # For GUI editors, often they detach, so no need for -PassThru or complex handling
                    Start-Process -FilePath $editorCommand -ArgumentList $ResolvedPostHtmRawPath -ErrorAction Stop
                    # Get just the executable name for the message
                    $editorExeName = ($editorCommand -split '[\\/]')[-1]
                    Write-Host "Launched editor '$editorExeName' for '$ResolvedPostHtmRawPath'."
                }
                catch {
                    Write-Warning "Failed to launch editor '$editorCommand' for '$ResolvedPostHtmRawPath'. Error: $($_.Exception.Message)"
                }
            }
            else {
                # Get-EditorCommand already issues a Write-Warning if no editor is found.
                # This message gives context-specific advice for the Invoke-Post command.
                Write-Host "No suitable editor found or configured to open '$ResolvedPostHtmRawPath'. Please open it manually to edit."
            }

            # --- TUI Prompt for P/E/S for newly created files in interactive mode ---
            if ($Global:IsInteractiveMode -and $newFileCreated) {
                $userAction = ""
                do {
                    Write-Host "`nPost '$($ResolvedPostHtmRawPath | Split-Path -Leaf)' has been prepared/updated." -ForegroundColor Yellow
                    $choices = @(
                        [pscustomobject]@{ Name = "Publish"; Letter = "P"; Description = "Generate HTML and update indexes now." }
                        [pscustomobject]@{ Name = "Edit";    Letter = "E"; Description = "Re-open in editor / continue editing." }
                        [pscustomobject]@{ Name = "Save as Draft";   Letter = "S"; Description = "Skip HTML generation and index updates for now." }
                    )
                    $choices | ForEach-Object { Write-Host ("  [{0}] {1,-15} - {2}" -f $_.Letter, $_.Name, $_.Description) }
                    $actionChoice = Read-Host -Prompt "Enter action (P/E/S)"

                    $userAction = $actionChoice.ToUpper()

                    switch ($userAction) {
                        "P" { Write-Verbose "User chose to Publish." }
                        "E" {
                            Write-Verbose "User chose to Edit again."
                            $editorToReopen = Get-EditorCommand
                            if (-not [string]::IsNullOrEmpty($editorToReopen)) {
                                Write-Verbose "Attempting to re-open '$ResolvedPostHtmRawPath' with editor: $editorToReopen"
                                try {
                                    Start-Process -FilePath $editorToReopen -ArgumentList $ResolvedPostHtmRawPath -ErrorAction Stop
                                } catch { Write-Warning "Failed to re-launch editor '$editorToReopen'. Error: $($_.Exception.Message)" }
                            } else { Write-Warning "No editor found to re-open." }
                        }
                        "S" {
                            Write-Verbose "User chose to Save as Draft."
                            Write-Host "Post '$ResolvedPostHtmRawPath' saved as a draft. HTML generation and index updates will be skipped." -ForegroundColor Green
                            return # Exit Invoke-Post entirely
                        }
                        default {
                            Write-Warning "Invalid selection. Please choose P, E, or S."
                            $userAction = "E" # Force loop to re-prompt by making it seem like Edit was chosen
                        }
                    }
                } while ($userAction -eq "E") # Loop as long as user wants to edit or enters invalid choice that defaults to E
            } # --- End TUI P/E/S Prompt ---

        } catch { # This catch is for the block that creates the new file from skeleton
            Write-Error "Failed to create new post from skeleton at $ResolvedPostHtmRawPath: $($_.Exception.Message)"
            return # Critical failure for this operation
        }
    } else { # This else is for if (-not (Test-Path $ResolvedPostHtmRawPath -PathType Leaf))
        Write-Host "Processing existing post: $ResolvedPostHtmRawPath"
        # For existing posts, we don't show the P/E/S prompt, just proceed to generate.
        # If we wanted P/E/S for existing posts, $newFileCreated would need different logic.
    }

    # 3. Determine Output Path (This is fine, but $ResolvedPostHtmRawPath should be used with -LiteralPath)
    $OutputFileName = [System.IO.Path]::GetFileNameWithoutExtension($ResolvedPostHtmRawPath) + ".html"
    $OutputFilePath = Join-Path -Path (Split-Path -Path $ResolvedPostHtmRawPath) -ChildPath $OutputFileName
    Write-Verbose "Output HTML file will be: $OutputFilePath"

    # 4. Process the Post
    $Timestamp = (Get-Item -LiteralPath $ResolvedPostHtmRawPath).LastWriteTime
    Write-Verbose "Timestamp for post $ResolvedPostHtmRawPath is $Timestamp"

    New-BlogPostHtml -SourceFilePath $ResolvedPostHtmRawPath -OutputFilePath $OutputFilePath -Timestamp $Timestamp

    if (-not (Test-Path $OutputFilePath -PathType Leaf)) {
        Write-Warning "HTML file $OutputFilePath was not generated as expected by New-BlogPostHtml. Skipping index updates for this post."
        return
    }

    Write-Verbose "Post HTML generation appears successful. Proceeding to update indexes."
    Update-MainIndex
    Update-AllPostsIndex
    Update-TagsIndex
    Write-Host "Invoke-Post for '$($PostHtmRawPathParameter)' completed."
}

# Function to update tag index pages (all_tags.html and individual tag_*.html files)
function Update-TagsIndex {
    Write-Host "Updating tag index pages..."
    Write-Verbose "Global AllTagsFile path: $AllTagsFile"

    # 1. Initialize Data Structures
    $tagsCollection = @{}

    # 2. Find Source Files & Gather Tag Data
    Write-Verbose "Scanning $ContentRoot for .htmraw files to build tag collections."
    $allHtmRawFiles = Get-ChildItem -Path $ContentRoot -Filter *.htmraw -Recurse -ErrorAction SilentlyContinue
    if ($null -eq $allHtmRawFiles -or $allHtmRawFiles.Count -eq 0) {
        Write-Warning "No .htmraw files found in $ContentRoot. Tag indexes will be empty or reflect no posts."
        # Allow to proceed to generate empty/default tag pages
    }

    $resolvedFullContentRootPath = (Resolve-Path $ContentRoot -ErrorAction SilentlyContinue).Path
     if (-not $resolvedFullContentRootPath) {
        Write-Error "Cannot resolve ContentRoot full path: $ContentRoot. Aborting Tags index update."
        return
    }

    foreach ($htmrawFile in $allHtmRawFiles) {
        Write-Verbose "Processing tags for $($htmrawFile.FullName)"
        if ($htmrawFile.FullName.StartsWith((Resolve-Path $TemplatesDir -ErrorAction SilentlyContinue).Path)) {
            Write-Verbose "Skipping file in TemplatesDir: $($htmrawFile.FullName)"
            continue
        }

        $parsedData = Parse-HtmRawContent -RawContent (Get-HtmRawSourceFile -FilePath $htmrawFile.FullName)
        if (-not $parsedData) {
            Write-Warning "Could not parse $($htmrawFile.FullName), skipping for Tags index."
            continue
        }

        $relativeHtmRawPath = $htmrawFile.FullName.Substring($resolvedFullContentRootPath.Length)
        if ($relativeHtmRawPath.StartsWith('/') -or $relativeHtmRawPath.StartsWith('\')) {
            $relativeHtmRawPath = $relativeHtmRawPath.Substring(1)
        }
        $htmlLink = ($relativeHtmRawPath -replace [regex]::Escape(".htmraw"), ".html") -replace '\\', '/'

        $postTimestamp = $htmrawFile.LastWriteTime

        foreach ($rawTag in $parsedData.Tags) {
            $tag = $rawTag.Trim()
            if ([string]::IsNullOrWhiteSpace($tag)) {
                continue
            }
            Write-Verbose "Found tag '$tag' in $($htmrawFile.Name)"

            if (-not $tagsCollection.ContainsKey($tag)) {
                $tagsCollection[$tag] = [System.Collections.Generic.List[PSCustomObject]]::new()
            }
            $tagsCollection[$tag].Add([PSCustomObject]@{
                Title            = $parsedData.Title
                HtmlRelativePath = $htmlLink
                Timestamp        = $postTimestamp
            })
        }
    }
    Write-Verbose "Finished collecting tags. Found $($tagsCollection.Keys.Count) unique tags."

    # 3. Sort Posts within Each Tag Collection
    Write-Verbose "Sorting posts within each tag collection..."
    foreach ($tagKey in $tagsCollection.Keys) {
        $tagsCollection[$tagKey] = $tagsCollection[$tagKey] | Sort-Object -Property Timestamp -Descending
    }

    # Get template contents once
    $cmsHeaderContent = Get-TemplateContent -TemplatePath $Global:HeaderTemplate
    $cmsFooterContent = Get-TemplateContent -TemplatePath $Global:FooterTemplate
    $cmsBeginContent = Get-TemplateContent -TemplatePath $Global:BeginTemplate
    $cmsEndContent = Get-TemplateContent -TemplatePath $Global:EndTemplate

    # Get the dynamic Spelunker header once, if templates are valid
    $baseSpelunkerHeaderHtml = $null
    if ($null -ne $cmsHeaderContent -and $null -ne $cmsFooterContent -and $null -ne $cmsBeginContent -and $null -ne $cmsEndContent) {
        $baseSpelunkerHeaderHtml = Get-SpelunkerPageHeaderHtml # Renamed for clarity
    } else {
        Write-Error "One or more base template files ($($Global:HeaderTemplate), etc.) could not be read. Aborting all tag page generation."
        return # Exit function if essential templates are missing
    }

    # 4. Generate all_tags.html
    Write-Verbose "Generating $AllTagsFile..."
    $allTagsPageBuilder = New-Object System.Text.StringBuilder
    [void]$allTagsPageBuilder.AppendLine("<h1>All Tags</h1>")
    [void]$allTagsPageBuilder.AppendLine("<ul>")

    if ($tagsCollection.Keys.Count -gt 0) {
        foreach ($tagKey in ($tagsCollection.Keys | Sort-Object)) {
            $safeTagFileName = "tag_$($tagKey -replace '[^a-zA-Z0-9_]', '_').html"
            Write-Verbose "Adding tag '$tagKey' to $AllTagsFile, linking to $safeTagFileName"
            [void]$allTagsPageBuilder.AppendLine("<li><a href=""$safeTagFileName"">$tagKey</a> ($($tagsCollection[$tagKey].Count) posts)</li>")
        }
    } else {
        Write-Verbose "No tags found to list in $AllTagsFile."
        [void]$allTagsPageBuilder.AppendLine("<li>No tags found.</li>")
    }
    [void]$allTagsPageBuilder.AppendLine("</ul>")

    $headerWithPageTitle_AllTags = $cmsHeaderContent -replace '</head>', "<title>$($Global:SiteTitle) - All Tags</title></head>"

    # Inject search box and buttons for all_tags.html
    $finalHeader_AllTags = $baseSpelunkerHeaderHtml
    if ($Global:SearchBoxPages -match "all_tags") {
        $searchBoxHtml = Get-SearchBoxHtml
        $finalHeader_AllTags = $finalHeader_AllTags.Replace("<!--SPELUNKER_SEVENTHBUTTON-->", $searchBoxHtml)
    }
    # Add RSS button to all_tags.html (example, using FIFTH placeholder)
    $rssButtonHtml_AllTags = Get-RssButtonHtml
    $finalHeader_AllTags = $finalHeader_AllTags.Replace("<!--SPELUNKER_FIFTHBUTTON-->", $rssButtonHtml_AllTags)
    # Clear other placeholders for all_tags.html
    $finalHeader_AllTags = $finalHeader_AllTags -replace "<!--SPELUNKER_SECONDBUTTON-->", ""
    $finalHeader_AllTags = $finalHeader_AllTags -replace "<!--SPELUNKER_THIRDBUTTON-->", ""
    $finalHeader_AllTags = $finalHeader_AllTags -replace "<!--SPELUNKER_FOURTHBUTTON-->", ""
    $finalHeader_AllTags = $finalHeader_AllTags -replace "<!--SPELUNKER_SIXTHBUTTON-->", ""
    $finalHeader_AllTags = $finalHeader_AllTags -replace "<!--SPELUNKER_SEVENTHBUTTON-->", "" # If not used by search

    $fullAllTagsHtmlBuilder = New-Object System.Text.StringBuilder
    [void]$fullAllTagsHtmlBuilder.Append($headerWithPageTitle_AllTags)
    [void]$fullAllTagsHtmlBuilder.Append($finalHeader_AllTags)
    [void]$fullAllTagsHtmlBuilder.Append($cmsBeginContent)
    [void]$fullAllTagsHtmlBuilder.Append($allTagsPageBuilder.ToString())
    [void]$fullAllTagsHtmlBuilder.Append($cmsEndContent)
    [void]$fullAllTagsHtmlBuilder.Append($cmsFooterContent)

    try {
        $pageDepthAllTags = Determine-PageDepth -PagePath $AllTagsFile -BaseSitePath $Global:ContentRoot
        $finalHtmlAllTags = Adjust-AssetPaths -HtmlContentString $fullAllTagsHtmlBuilder.ToString() -PageDepth $pageDepthAllTags
        Set-Content -Path $AllTagsFile -Value $finalHtmlAllTags -Force -ErrorAction Stop
        Write-Host "All Tags index page updated: $AllTagsFile"
    } catch {
        Write-Error "Failed to write All Tags index page to $AllTagsFile: $($_.Exception.Message)"
    }

    # 5. Generate Individual tag_TAGNAME.html Pages
    Write-Verbose "Generating individual tag pages..."
    foreach ($tagKey in $tagsCollection.Keys) {
        $safeTagFileName = "tag_$($tagKey -replace '[^a-zA-Z0-9_]', '_').html"
        $tagPagePath = Join-Path -Path $Global:ContentRoot -ChildPath $safeTagFileName
        Write-Verbose "Generating tag page for '$tagKey' at $tagPagePath"

        $singleTagPageBuilder = New-Object System.Text.StringBuilder
        [void]$singleTagPageBuilder.AppendLine("<h1>Posts tagged ""$tagKey""</h1>")
        [void]$singleTagPageBuilder.AppendLine("<ul>")

        if ($tagsCollection[$tagKey].Count -gt 0) {
             foreach ($post in $tagsCollection[$tagKey]) { # Already sorted
                $formattedDate = $post.Timestamp.ToString("dddd, MMMM dd, yyyy")
                [void]$singleTagPageBuilder.AppendLine("<li><a href=""$($post.HtmlRelativePath)"">$($post.Title)</a> - $formattedDate</li>")
            }
        } else {
            [void]$singleTagPageBuilder.AppendLine("<li>No posts found for this tag.</li>")
        }
        [void]$singleTagPageBuilder.AppendLine("</ul>")

        $headerWithTagPageTitle = $cmsHeaderContent -replace '</head>', "<title>Posts tagged '$($tagKey)' - $($Global:SiteTitle)</title></head>"

        # Inject search box for individual tag_*.html pages
        $finalHeader_SingleTag = $baseSpelunkerHeaderHtml
        if ($Global:SearchBoxPages -match "tag_page") { # Assuming "tag_page" as type
            $searchBoxHtml_SingleTag = Get-SearchBoxHtml
            $finalHeader_SingleTag = $finalHeader_SingleTag.Replace("<!--SPELUNKER_SEVENTHBUTTON-->", $searchBoxHtml_SingleTag)
        }
        # Clear all other button placeholders for individual tag pages
        $finalHeader_SingleTag = $finalHeader_SingleTag -replace "<!--SPELUNKER_SECONDBUTTON-->", ""
        $finalHeader_SingleTag = $finalHeader_SingleTag -replace "<!--SPELUNKER_THIRDBUTTON-->", ""
        $finalHeader_SingleTag = $finalHeader_SingleTag -replace "<!--SPELUNKER_FOURTHBUTTON-->", ""
        $finalHeader_SingleTag = $finalHeader_SingleTag -replace "<!--SPELUNKER_FIFTHBUTTON-->", ""
        $finalHeader_SingleTag = $finalHeader_SingleTag -replace "<!--SPELUNKER_SIXTHBUTTON-->", ""
        $finalHeader_SingleTag = $finalHeader_SingleTag -replace "<!--SPELUNKER_SEVENTHBUTTON-->", "" # If not used by search

        $fullSingleTagHtmlBuilder = New-Object System.Text.StringBuilder
        [void]$fullSingleTagHtmlBuilder.Append($headerWithTagPageTitle)
        [void]$fullSingleTagHtmlBuilder.Append($finalHeader_SingleTag)
        [void]$fullSingleTagHtmlBuilder.Append($cmsBeginContent)
        [void]$fullSingleTagHtmlBuilder.Append($singleTagPageBuilder.ToString())
        [void]$fullSingleTagHtmlBuilder.Append($cmsEndContent)
        [void]$fullSingleTagHtmlBuilder.Append($cmsFooterContent)

        try {
            $pageDepthSingleTag = Determine-PageDepth -PagePath $tagPagePath -BaseSitePath $Global:ContentRoot
            $finalHtmlSingleTag = Adjust-AssetPaths -HtmlContentString $fullSingleTagHtmlBuilder.ToString() -PageDepth $pageDepthSingleTag
            Set-Content -Path $tagPagePath -Value $finalHtmlSingleTag -Force -ErrorAction Stop
            Write-Host "Tag page generated: $tagPagePath"
        } catch {
            Write-Error "Failed to write tag page to $tagPagePath: $($_.Exception.Message)"
        }
    }
    Write-Host "Tag index pages update complete."
}

# Function to update the all_posts.html page
function Update-AllPostsIndex {
    Write-Host "Updating All Posts index page: $AllPostsFile"
    Write-Verbose "Global AllPostsFile path: $AllPostsFile"

    # 1. Find relevant .htmraw source files
    Write-Verbose "Scanning $ContentRoot for .htmraw files to build All Posts index."
    $allHtmRawFiles = Get-ChildItem -Path $ContentRoot -Filter *.htmraw -Recurse -ErrorAction SilentlyContinue
     if ($null -eq $allHtmRawFiles -or $allHtmRawFiles.Count -eq 0) {
        Write-Warning "No .htmraw files found in $ContentRoot. All Posts index will be empty or reflect no posts."
        # Allow to proceed to generate an empty index
    }

    $postObjects = @()
    $resolvedFullContentRootPath = (Resolve-Path $ContentRoot -ErrorAction SilentlyContinue).Path
    if (-not $resolvedFullContentRootPath) {
        Write-Error "Cannot resolve ContentRoot full path: $ContentRoot. Aborting All Posts index update."
        return
    }

    foreach ($htmrawFile in $allHtmRawFiles) {
        Write-Verbose "Processing $($htmrawFile.FullName) for All Posts index."
        if ($htmrawFile.FullName.StartsWith((Resolve-Path $TemplatesDir -ErrorAction SilentlyContinue).Path)) {
            Write-Verbose "Skipping file in TemplatesDir: $($htmrawFile.FullName)"
            continue
        }

        $parsedData = Parse-HtmRawContent -RawContent (Get-HtmRawSourceFile -FilePath $htmrawFile.FullName)
        if (-not $parsedData) {
            Write-Warning "Could not parse $($htmrawFile.FullName), skipping for All Posts index."
            continue
        }

        $relativeHtmRawPath = $htmrawFile.FullName.Substring($resolvedFullContentRootPath.Length)
        if ($relativeHtmRawPath.StartsWith('/') -or $relativeHtmRawPath.StartsWith('\')) {
            $relativeHtmRawPath = $relativeHtmRawPath.Substring(1)
        }
        $htmlLink = ($relativeHtmRawPath -replace [regex]::Escape(".htmraw"), ".html") -replace '\\', '/'

        $postObjects += [PSCustomObject]@{
            Title            = $parsedData.Title
            HtmlRelativePath = $htmlLink
            Timestamp        = $htmrawFile.LastWriteTime
        }
    }
    Write-Verbose "Finished collecting post data for All Posts index. $($postObjects.Count) posts found."

    # 2. Sort Posts (newest first)
    Write-Verbose "Sorting posts for All Posts index."
    $sortedPosts = $postObjects | Sort-Object -Property Timestamp -Descending

    # 3. Generate HTML content for the All Posts page
    $allPostsContentBuilder = New-Object System.Text.StringBuilder
    [void]$allPostsContentBuilder.AppendLine("<h1>All Posts</h1>")

    $currentGroupHeader = ""
    if ($sortedPosts.Count -gt 0) {
        Write-Verbose "Generating list entries for All Posts page with $($sortedPosts.Count) posts."
        foreach ($post in $sortedPosts) {
            $postGroupHeader = $post.Timestamp.ToString("MMMM yyyy")
            if ($postGroupHeader -ne $currentGroupHeader) {
                if ($currentGroupHeader -ne "") {
                    [void]$allPostsContentBuilder.AppendLine("</ul>")
                }
                $currentGroupHeader = $postGroupHeader
                Write-Verbose "Creating new group for All Posts index: $currentGroupHeader"
                [void]$allPostsContentBuilder.AppendLine("<h2>$currentGroupHeader</h2><ul>")
            }
            $formattedDate = $post.Timestamp.ToString("dddd, MMMM dd, yyyy")
            [void]$allPostsContentBuilder.AppendLine("<li><a href=""$($post.HtmlRelativePath)"">$($post.Title)</a> - $formattedDate</li>")
        }
        [void]$allPostsContentBuilder.AppendLine("</ul>")
    } else {
        Write-Verbose "No posts to list on All Posts page."
        [void]$allPostsContentBuilder.AppendLine("<p>No posts found.</p>")
    }

    # 4. Construct Full All Posts Page
    Write-Verbose "Constructing full HTML for $AllPostsFile."
    $cmsHeaderContent = Get-TemplateContent -TemplatePath $Global:HeaderTemplate
    $cmsFooterContent = Get-TemplateContent -TemplatePath $Global:FooterTemplate
    $cmsBeginContent = Get-TemplateContent -TemplatePath $Global:BeginTemplate
    $cmsEndContent = Get-TemplateContent -TemplatePath $Global:EndTemplate

    if ($null -eq $cmsHeaderContent -or $null -eq $cmsFooterContent -or $null -eq $cmsBeginContent -or $null -eq $cmsEndContent) {
        Write-Error "One or more base template files ($($Global:HeaderTemplate), $($Global:FooterTemplate), $($Global:BeginTemplate), $($Global:EndTemplate)) could not be read or are empty for All Posts index generation. Aborting $AllPostsFile generation."
        return # Was: Aborting $AllPostsFile generation. return
    }

    $headerWithPageTitle = $cmsHeaderContent -replace '</head>', "<title>$($Global:SiteTitle) - All Posts</title></head>"

    $baseSpelunkerHeaderHtml = Get-SpelunkerPageHeaderHtml

    # Inject Search Box and specific buttons for Update-AllPostsIndex (all_posts.html)
    $finalHeaderHtml = $baseSpelunkerHeaderHtml
    if ($Global:SearchBoxPages -match "all_posts") {
        $searchBoxHtml = Get-SearchBoxHtml
        $finalHeaderHtml = $finalHeaderHtml.Replace("<!--SPELUNKER_SEVENTHBUTTON-->", $searchBoxHtml)
    }
    # Potentially add RSS button to all_posts page
    $rssButtonHtml = Get-RssButtonHtml
    $finalHeaderHtml = $finalHeaderHtml.Replace("<!--SPELUNKER_FIFTHBUTTON-->", $rssButtonHtml) # Assuming FIFTH is a good spot

    # Clear any remaining/other button placeholders
    $finalHeaderHtml = $finalHeaderHtml -replace "<!--SPELUNKER_SECONDBUTTON-->", ""
    $finalHeaderHtml = $finalHeaderHtml -replace "<!--SPELUNKER_THIRDBUTTON-->", ""
    $finalHeaderHtml = $finalHeaderHtml -replace "<!--SPELUNKER_FOURTHBUTTON-->", ""
    # $finalHeaderHtml = $finalHeaderHtml -replace "<!--SPELUNKER_FIFTHBUTTON-->", "" # Already used or cleared
    $finalHeaderHtml = $finalHeaderHtml -replace "<!--SPELUNKER_SIXTHBUTTON-->", ""
    $finalHeaderHtml = $finalHeaderHtml -replace "<!--SPELUNKER_SEVENTHBUTTON-->", "" # Clear if not used by search


    $fullAllPostsHtmlBuilder = New-Object System.Text.StringBuilder
    [void]$fullAllPostsHtmlBuilder.Append($headerWithPageTitle)
    [void]$fullAllPostsHtmlBuilder.Append($finalHeaderHtml)      # Header with injected content
    [void]$fullAllPostsHtmlBuilder.Append($cmsBeginContent)
    [void]$fullAllPostsHtmlBuilder.Append($allPostsContentBuilder.ToString()) # Actual list of posts
    [void]$fullAllPostsHtmlBuilder.Append($cmsEndContent)
    [void]$fullAllPostsHtmlBuilder.Append($cmsFooterContent)

    try {
        $pageDepth = Determine-PageDepth -PagePath $AllPostsFile -BaseSitePath $Global:ContentRoot
        $finalHtmlContent = Adjust-AssetPaths -HtmlContentString $fullAllPostsHtmlBuilder.ToString() -PageDepth $pageDepth
        Set-Content -Path $AllPostsFile -Value $finalHtmlContent -Force -ErrorAction Stop
        Write-Host "All Posts index page updated: $AllPostsFile"
    } catch {
        Write-Error "Failed to write All Posts index page to $AllPostsFile: $($_.Exception.Message)"
    }
}

# Helper function to strip HTML tags
function ConvertFrom-HtmlToText {
    param (
        [string]$HtmlContent
    )
    Write-Verbose "Stripping HTML from content of length $($HtmlContent.Length)"
    return $HtmlContent -replace "<[^>]+>", ""
}

# Function to create HTML for a new blog post
function New-BlogPostHtml {
    param(
        [Parameter(Mandatory=$true)]
        [string]$SourceFilePath,

        [Parameter(Mandatory=$true)]
        [string]$OutputFilePath,

        [datetime]$Timestamp = (Get-Date)
    )
    Write-Verbose "Starting New-BlogPostHtml for source: $SourceFilePath, output: $OutputFilePath"

    $RawContent = Get-HtmRawSourceFile -FilePath $SourceFilePath
    if ($null -eq $RawContent) { # Check for $null specifically
        Write-Error "Failed to read source file '$SourceFilePath' or file is empty for New-BlogPostHtml. Aborting this post."
        return
    }
    Write-Verbose "Successfully read source file $SourceFilePath."

    $ParsedContent = Parse-HtmRawContent -RawContent $RawContent
    # Parse-HtmRawContent returns a PSCustomObject with defaults, so no specific null check needed here.
    Write-Verbose "Successfully parsed content for $SourceFilePath. Title: '$($ParsedContent.Title)'"

    $HeaderContent = Get-TemplateContent -TemplatePath $HeaderTemplate
    $FooterContent = Get-TemplateContent -TemplatePath $FooterTemplate
    $BeginContent = Get-TemplateContent -TemplatePath $BeginTemplate
    $EndContent = Get-TemplateContent -TemplatePath $EndTemplate

    if ($null -eq $HeaderContent -or $null -eq $FooterContent -or $null -eq $BeginContent -or $null -eq $EndContent) {
        Write-Error "One or more critical template files ($HeaderTemplate, $FooterTemplate, $BeginTemplate, $EndTemplate) could not be read or are empty. Aborting generation of '$OutputFilePath'."
        return
    }
    Write-Verbose "All base templates successfully read for '$OutputFilePath'."

    # Inject title into header
    # A simple approach: replace </head> with <title>$Title</title></head>
    # This assumes </head> exists and is unique enough for this simple replacement.
    $pageTitleForHead = if (-not [string]::IsNullOrWhiteSpace($ParsedContent.Title)) { $ParsedContent.Title } else { "Untitled Post" }
    $HeaderWithPageTitle = $HeaderContent -replace '</head>', "<title>$($pageTitleForHead) - $($Global:SiteTitle)</title></head>"

    $baseSpelunkerHeaderHtml = Get-SpelunkerPageHeaderHtml # Base header with placeholders

    # Inject Search Box for New-BlogPostHtml (post pages)
    $finalHeaderHtml = $baseSpelunkerHeaderHtml
    if ($Global:SearchBoxPages -match "post") { # Check if "post" is in SearchBoxPages
        $searchBoxHtml = Get-SearchBoxHtml
        $finalHeaderHtml = $finalHeaderHtml.Replace("<!--SPELUNKER_SEVENTHBUTTON-->", $searchBoxHtml)
    }
    # Clear all other page-specific button placeholders for posts
    $finalHeaderHtml = $finalHeaderHtml -replace "<!--SPELUNKER_SECONDBUTTON-->", "" # Second button often for subhome, not on post page
    $finalHeaderHtml = $finalHeaderHtml -replace "<!--SPELUNKER_THIRDBUTTON-->", ""
    $finalHeaderHtml = $finalHeaderHtml -replace "<!--SPELUNKER_FOURTHBUTTON-->", ""
    $finalHeaderHtml = $finalHeaderHtml -replace "<!--SPELUNKER_FIFTHBUTTON-->", ""
    $finalHeaderHtml = $finalHeaderHtml -replace "<!--SPELUNKER_SIXTHBUTTON-->", ""
    # Also clear seventh if search box was not injected
    $finalHeaderHtml = $finalHeaderHtml -replace "<!--SPELUNKER_SEVENTHBUTTON-->", ""


    # Construct HTML
    $HtmlBuilder = New-Object System.Text.StringBuilder
    [void]$HtmlBuilder.Append($HeaderWithPageTitle) # This is from cms_header.txt, includes <html>, <head> with specific title, <body> tag
    [void]$HtmlBuilder.Append($finalHeaderHtml)     # Spelunker's dynamic header, now with search box (if applicable) & cleared placeholders
    [void]$HtmlBuilder.Append($BeginContent)        # This is from cms_begin.txt, typically opens main content columns
    [void]$HtmlBuilder.Append($ParsedContent.Body)  # The actual post body

    # Add tags if any
    if ($ParsedContent.Tags.Count -gt 0) {
        $TagsString = $ParsedContent.Tags -join ", "
        [void]$HtmlBuilder.Append("<p>Tags: $TagsString</p>")
    }

    [void]$HtmlBuilder.Append($EndContent)
    [void]$HtmlBuilder.Append($FooterContent)

    try {
        $pageDepth = Determine-PageDepth -PagePath $OutputFilePath -BaseSitePath $Global:ContentRoot
        $finalHtmlContent = Adjust-AssetPaths -HtmlContentString $HtmlBuilder.ToString() -PageDepth $pageDepth
        Set-Content -Path $OutputFilePath -Value $finalHtmlContent -Force -ErrorAction Stop
        Write-Host "Successfully generated $OutputFilePath (Timestamp: $Timestamp)"
    } catch {
        Write-Error "Failed to write HTML to $OutputFilePath: $($_.Exception.Message)" # More specific error
    }
}

# Function to get raw content from a file
function Get-HtmRawSourceFile {
    param (
        [string]$FilePath
    )
    Write-Verbose "Attempting to read file: $FilePath"
    try {
        if (Test-Path $FilePath -PathType Leaf) { # Ensure it's a file
            Write-Verbose "File confirmed to exist: $FilePath"
            return Get-Content -Raw -Path $FilePath -ErrorAction Stop
        } else {
            Write-Error "Source file not found or is not a file: $FilePath"
            return $null
        }
    } catch {
        Write-Error "Exception while reading file $FilePath: $($_.Exception.Message)" # More specific error
        return $null
    }
}

# Function to parse raw HTML content
function Parse-HtmRawContent {
    param (
        [string]$RawContent
    )
    Write-Verbose "Parsing raw content. Length: $($RawContent.Length)"

    $TitleMatch = $RawContent | Select-String -Pattern '<h1>(.*?)</h1>'
    $Title = if ($TitleMatch) { $TitleMatch.Matches[0].Groups[1].Value } else { "Untitled Post" }

    $TagsMatch = $RawContent | Select-String -Pattern '<!--RawTags:(.*?)-->'
    $Tags = if ($TagsMatch) {
        $TagsMatch.Matches[0].Groups[1].Value.Split(',') | ForEach-Object {$_.Trim()}
    } else {
        @()
    }

    $BodyMatch = $RawContent | Select-String -Pattern '(?s)<body>(.*?)</body>'
    $Body = if ($BodyMatch) { $BodyMatch.Matches[0].Groups[1].Value } else { "" }

    return [PSCustomObject]@{
        Title = $Title
        Tags = $Tags
        Body = $Body
        RawContent = $RawContent
    }
}

# Function to get content from a template file
function Get-TemplateContent {
    param (
        [string]$TemplatePath
    )
    Write-Verbose "Attempting to read template file: $TemplatePath"
    try {
        if (Test-Path $TemplatePath -PathType Leaf) { # Ensure it's a file
            Write-Verbose "Template file confirmed to exist: $TemplatePath"
            return Get-Content -Raw -Path $TemplatePath -ErrorAction Stop
        } else {
            Write-Error "Template file not found or is not a file: $TemplatePath"
            return $null
        }
    } catch {
        Write-Error "Exception while reading template file $TemplatePath: $($_.Exception.Message)" # More specific error
        return $null
    }
}

# Command handling
switch ($Command) {
    "rebuild" {
        Invoke-Rebuild
    }
    "post" {
        # $PSBoundParameters contains parameters explicitly passed to the script.
        # We need to ensure 'PostHtmRawPathParameter' (or whatever name we give the param in Invoke-Post)
        # is correctly passed if the user specifies it with a similar name on the command line.
        # The script's main param() block does not define -PostFilePath, so it won't be in $PSBoundParameters directly
        # if called like ./spelunker.ps1 -Command post -PostFilePath foo.htmraw
        # Instead, PowerShell passes extra parameters if the command (Invoke-Post) accepts them.
        # Let's assume the user calls: ./spelunker.ps1 -Command post drafts/post.htmraw
        # $args would contain 'drafts/post.htmraw' if not explicitly named.
        # For robust handling, we should add PostHtmRawPathParameter to the main param() block
        # or rely on $args if Invoke-Post is called directly with it.

        # Given current script structure, Invoke-Post is called with a named parameter.
        # The main script needs a way to receive this path.
        # Let's assume the command line is like:
        # ./spelunker.ps1 -Command post -SpecificPostPath "drafts/my-post.htmraw"
        # And the main param() block is updated to: param([string]$Path = "www/news", [string]$Command, [string]$SpecificPostPath)
        # Then, in the switch: Invoke-Post -PostHtmRawPathParameter $SpecificPostPath

        # For now, let's adjust the switch to expect $PSBoundParameters['PostHtmRawPathParameter']
        # This means the user *must* call it like:
        # ./spelunker.ps1 -Command post -PostHtmRawPathParameter "drafts/my-post.htmraw"
        # And the main param block must be updated.

        if ($PSBoundParameters.ContainsKey('PostHtmRawPathParameter')) {
            Invoke-Post -PostHtmRawPathParameter $PSBoundParameters['PostHtmRawPathParameter']
        } elseif ($PSBoundParameters.ContainsKey('PostFilePath')) {
            # Legacy or alternative naming, let's support it for now.
            Invoke-Post -PostHtmRawPathParameter $PSBoundParameters['PostFilePath']
        }
        else {
            Write-Error "For -Command 'post', please specify -PostHtmRawPathParameter or -PostFilePath."
        }
    }
    "edit" {
        $filePathToEdit = $null
        if ($PSBoundParameters.ContainsKey('EditHtmRawPathParameter')) {
            $filePathToEdit = $EditHtmRawPathParameter
        } elseif ($PSBoundParameters.ContainsKey('EditFilePath')) { # Alias for EditHtmRawPathParameter
            $filePathToEdit = $EditFilePath
        }
        # Invoke-Edit will handle interactive prompting if $filePathToEdit is $null and mode is interactive.
        # It will also handle erroring out if $filePathToEdit is $null and not interactive.
        Invoke-Edit -EditFilePathParameter $filePathToEdit
    }
    default {
        if ([string]::IsNullOrWhiteSpace($Command)) {
            Write-Error "No command specified. Use -Command <command_name> (e.g., post, edit, rebuild) or run with the -Interactive switch for a menu."
        } else {
            Write-Error "Unknown command: '$Command'. Valid commands are post, edit, rebuild. Or use -Interactive for a menu."
        }
    }
}
