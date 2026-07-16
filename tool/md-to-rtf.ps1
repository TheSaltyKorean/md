<#
.SYNOPSIS
  Render a Markdown file to a small, readable RTF document.

.DESCRIPTION
  The WiX MSI license dialog (and any other RTF-only surface) cannot display
  Markdown natively — fed the raw source it shows literal '#', '**', '[x](y)'
  markup. This converts the common Markdown constructs used by our LICENSE.md
  (headings, bold/italic, links, autolinks, inline code, blockquotes, bullet
  lists, horizontal rules) into formatted RTF so the dialog reads cleanly.

  It is intentionally a small, dependency-free subset — enough for a license /
  notice document, not a general CommonMark renderer. Output is ASCII RTF.

.EXAMPLE
  pwsh tool/md-to-rtf.ps1 -InputPath LICENSE.md -OutputPath license.rtf
#>
[CmdletBinding()]
param(
  [Parameter(Mandatory = $true)] [string] $InputPath,
  [Parameter(Mandatory = $true)] [string] $OutputPath
)

$ErrorActionPreference = 'Stop'

# Convert the inline Markdown in a single line to RTF. Literal RTF specials are
# escaped first; the control words we add afterwards therefore never collide
# with escaped user text.
function ConvertTo-RtfInline([string] $text) {
  # Escape RTF specials in the literal text: backslash and braces.
  $t = $text -replace '\\', '\\' -replace '\{', '\{' -replace '\}', '\}'

  # Links [label](url): anchor (#...) links keep just the label; external links
  # render as "label (url)" so the destination survives in a flat document.
  $t = [regex]::Replace($t, '\[([^\]]+)\]\(([^)]+)\)', {
      param($m)
      $label = $m.Groups[1].Value
      $url = $m.Groups[2].Value
      if ($url.StartsWith('#')) { $label } else { "$label ($url)" }
    })

  # Autolinks <https://…> / <mailto:…> -> the bare address.
  $t = [regex]::Replace($t, '<((?:https?://|mailto:)[^>]+)>', '$1')

  # Inline code `code` -> code (drop the backticks).
  $t = [regex]::Replace($t, '`([^`]+)`', '$1')

  # Emphasis, widest markers first so ** / * don't mis-match *** .
  $t = [regex]::Replace($t, '\*\*\*(.+?)\*\*\*', '\b\i $1\i0\b0 ')
  $t = [regex]::Replace($t, '\*\*(.+?)\*\*', '\b $1\b0 ')
  $t = [regex]::Replace($t, '\*(.+?)\*', '\i $1\i0 ')

  return $t
}

$lines = Get-Content -LiteralPath $InputPath
$sb = [System.Text.StringBuilder]::new()
[void]$sb.Append("{\rtf1\ansi\ansicpg1252\deff0{\fonttbl{\f0\fnil Segoe UI;}}`r`n")
[void]$sb.Append("\fs18`r`n")

# Heading point sizes (RTF half-points) by level, 1..6.
$headingSizes = @(32, 26, 22, 20, 18, 18)
$prevBlank = $false

foreach ($line in $lines) {
  $l = $line.TrimEnd()

  if ($l -eq '') {
    # Collapse runs of blank lines into a single paragraph break.
    if (-not $prevBlank) { [void]$sb.Append("\par`r`n") }
    $prevBlank = $true
    continue
  }
  $prevBlank = $false

  if ($l -match '^(#{1,6})\s+(.*)$') {
    $size = $headingSizes[[math]::Min($matches[1].Length - 1, 5)]
    $body = ConvertTo-RtfInline $matches[2]
    [void]$sb.Append("\fs$size\b $body\b0\fs18\par`r`n")
  }
  elseif ($l -match '^>\s?(.*)$') {
    $body = ConvertTo-RtfInline $matches[1]
    [void]$sb.Append("\li360\i $body\i0\li0\par`r`n")
  }
  elseif ($l -match '^[-*+]\s+(.*)$') {
    $body = ConvertTo-RtfInline $matches[1]
    [void]$sb.Append("\li360\bullet  $body\li0\par`r`n")
  }
  elseif ($l -match '^(-{3,}|\*{3,}|_{3,})$') {
    # Horizontal rule -> just vertical space.
    [void]$sb.Append("\par`r`n")
  }
  else {
    $body = ConvertTo-RtfInline $l
    [void]$sb.Append("$body\par`r`n")
  }
}

[void]$sb.Append('}')
Set-Content -LiteralPath $OutputPath -Encoding Ascii -Value $sb.ToString()
