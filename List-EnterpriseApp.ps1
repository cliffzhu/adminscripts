param(
  [string]$OutCsv = ".\enterprise_app_permissions.csv"
)

# 1) Connect with correct scopes
$Scopes = @(
  "Application.Read.All",
  "Directory.Read.All",
  "DelegatedPermissionGrant.Read.All",
  "AppRoleAssignment.ReadWrite.All"   # unfortunately needed for delegated auth in many tenants
)

Connect-MgGraph -Scopes $Scopes | Out-Null

Write-Host "Loading service principals (enterprise apps)..." -ForegroundColor Cyan
$servicePrincipals = Get-MgServicePrincipal -All -Property Id,DisplayName,AppId,AccountEnabled,PublisherName

# Build lookup for resource names
$spById = @{}
foreach ($sp in $servicePrincipals) { $spById[$sp.Id] = $sp }

Write-Host "Loading delegated permission grants (OAuth2PermissionGrants)..." -ForegroundColor Cyan
$oauthGrants = Get-MgOauth2PermissionGrant -All -Property ClientId,ConsentType,PrincipalId,ResourceId,Scope

$rows = New-Object System.Collections.Generic.List[object]

# -------------------------
# Delegated permissions
# -------------------------
Write-Host "Processing delegated permissions..." -ForegroundColor Cyan
foreach ($g in $oauthGrants) {
  if (-not $spById.ContainsKey($g.ClientId)) { continue }

  $client = $spById[$g.ClientId]
  $resourceName = if ($spById.ContainsKey($g.ResourceId)) { $spById[$g.ResourceId].DisplayName } else { $g.ResourceId }

  $scopes = @()
  if ($g.Scope) { $scopes = $g.Scope.Split(" ", [System.StringSplitOptions]::RemoveEmptyEntries) }

  if ($scopes.Count -eq 0) { $scopes = @("") }

  foreach ($s in $scopes) {
    $rows.Add([pscustomobject]@{
      EnterpriseAppName = $client.DisplayName
      EnterpriseAppObjectId = $client.Id
      EnterpriseAppAppId = $client.AppId
      PublisherName     = $client.PublisherName
      AccountEnabled    = $client.AccountEnabled

      PermissionType    = "Delegated"
      ResourceApp       = $resourceName
      Permission        = $s
      Consent           = if ($g.ConsentType -eq "AllPrincipals") { "Admin consent (All users)" } else { "User consent (Specific user)" }
      ConsentedForId    = if ($g.ConsentType -eq "AllPrincipals") { "" } else { $g.PrincipalId }
    }) | Out-Null
  }
}

# -------------------------
# Application permissions (AppRoleAssignments)
# -------------------------
# We must query per service principal id.
Write-Host "Processing application permissions (this can take a while)..." -ForegroundColor Cyan

# Cache resource app role maps: resourceSpId -> (DisplayName, RoleMap)
$resourceRoleCache = @{}

function Get-ResourceRoleInfo {
  param([string]$ResourceSpId)

  if ($resourceRoleCache.ContainsKey($ResourceSpId)) { return $resourceRoleCache[$ResourceSpId] }

  $resSp = if ($spById.ContainsKey($ResourceSpId)) {
    $spById[$ResourceSpId]
  } else {
    Get-MgServicePrincipal -ServicePrincipalId $ResourceSpId -Property Id,DisplayName,AppRoles
  }

  # ensure we have AppRoles populated
  if (-not $resSp.AppRoles) {
    $resSp = Get-MgServicePrincipal -ServicePrincipalId $ResourceSpId -Property Id,DisplayName,AppRoles
  }

  $map = @{}
  foreach ($r in ($resSp.AppRoles | Where-Object { $_.Id })) {
    $map[$r.Id.ToString()] = ($(if ($r.Value) { $r.Value } else { $r.DisplayName }))
  }

  $resourceRoleCache[$ResourceSpId] = @{
    DisplayName = $resSp.DisplayName
    RoleMap     = $map
  }

  return $resourceRoleCache[$ResourceSpId]
}

foreach ($sp in $servicePrincipals) {
  # Skip if you want: disabled apps, etc. (leave as-is for full export)
  try {
    $assignments = Get-MgServicePrincipalAppRoleAssignment -ServicePrincipalId $sp.Id -All -ErrorAction Stop
  } catch {
    continue
  }

  foreach ($a in $assignments) {
    $resourceId = $a.ResourceId
    $roleId     = $a.AppRoleId.ToString()

    $resInfo = Get-ResourceRoleInfo -ResourceSpId $resourceId
    $permName = if ($resInfo.RoleMap.ContainsKey($roleId)) { $resInfo.RoleMap[$roleId] } else { $roleId }

    $rows.Add([pscustomobject]@{
      EnterpriseAppName     = $sp.DisplayName
      EnterpriseAppObjectId = $sp.Id
      EnterpriseAppAppId    = $sp.AppId
      PublisherName         = $sp.PublisherName
      AccountEnabled        = $sp.AccountEnabled

      PermissionType        = "Application"
      ResourceApp           = $resInfo.DisplayName
      Permission            = $permName
      Consent               = "Admin (app-only)"
      ConsentedForId        = ""
    }) | Out-Null
  }
}

Write-Host "Writing CSV to $OutCsv ..." -ForegroundColor Green
$rows |
  Sort-Object EnterpriseAppName, PermissionType, ResourceApp, Permission |
  Export-Csv -NoTypeInformation -Encoding UTF8 -Path $OutCsv

Write-Host "Done. Exported $($rows.Count) rows." -ForegroundColor Green
