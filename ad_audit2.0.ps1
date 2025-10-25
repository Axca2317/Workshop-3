# ========================================================================
#               FIL: ad_audit.ps1
#   SYFTE: Skapa en Active Directory Audit-rapport baserad på JSON-export,
#   samt CSV över inaktiva användare (30+ dagar).

# =============================================================================
# 0) Förberedelser (mappar mm)
 

# $scriptRoot: full sökväg till mappen där detta script ligger
# Detta gör att vi kan köra scriptet varifrån som helst och ändå hitta JSON-filen.
$scriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Path

# Skapa en outputs-mapp om den inte finns
$outputDir = Join-Path $scriptRoot 'outputs'
if (-not (Test-Path $outputDir)) {
    New-Item -Path $outputDir -ItemType Directory | Out-Null
}

# =============================================================================
# 1) Läs in JSON till ett powershell objekt

# Vi läser in hela filen som EN sträng med -Raw. Detta är viktigt för JSON.

# Efter konvertering får vi ett PS-objekt med .domain, .users, .computers etc.

$jsonPath = Join-Path $scriptRoot 'ad_export.json'      # Bygger sökvägen till filen 
if (-not (Test-Path $jsonPath)) {
    # Säkerhetsfunktion som stoppar körningen om filen inte finns, 
    # så att vi inte fortsätter med tom data
    throw "Hittar inte filen 'ad_export.json' i $scriptRoot. Lägg filen där och kör igen."
}

# $jsonText: innehåller hela filens text
$jsonText = Get-Content -Path $jsonPath -Raw -Encoding UTF8

$data = $jsonText | ConvertFrom-Json    # Gör om texten till ett objekt som vi kan navigera med punktnotation



# =============================================================================
# 2) Enkla “metadata” ur JSON
 

# Dessa värden används i rapporten.
$domainName = $data.domain                  # Vi hämtar domännamn från json t.ex. "techcorp.local"
$exportDate = [datetime]$data.export_date   # Konverterar exportdatum från text till datumtyp
$totalUsers = $data.users.Count             # Räknar antal användare i listan
$totalComputers = $data.computers.Count     # Räknar antal datorer i listan

# =============================================================================
# 3) Datumgränser (nu & 30 dagar)
 


# $now: exakta klockslaget vid körning
$now = Get-Date
# $thirtyDaysAgo: tiden 30 dagar bakåt
$thirtyDaysAgo = $now.AddDays(-30)

# =============================================================================
# 4) Lista inaktiva användare (30+ dagar) "Vi bygger en lista över inaktiva användare"


#     Variabler i pipeline används en "speciell" variabel     $_ 
#     $_    =   "aktuellt objekt" som just nu passerar i pipen.
#     När vi skriver $._lastLogon menar vi egenskapen lastLogon på den användaren.
#     Vi gör om lastLogon-texten till [datetime] innan jämförelse.
#
#     Alternativt hade vi kunnat använda Select-Object och skapa en ny egenskap
#     med ((Get-Date) - [datetime]$_.lastLogon).Days

#   Vi börjar med alla users filtrerar på sista inloggning och väljer ut kolumner



$inactiveUsers =
$data.users |
Where-Object { # Följande klammer: Släpper bara igenom användare vars sista inloggning är äldre än gränsen
    # $_ = "den användare som för tillfället testas i filtret"
    # Gör om lastLogon (sträng) till [datetime] för korrekt datumjämförelse
    [datetime]$_.lastLogon -lt $thirtyDaysAgo
} |
# Skapa “beräknade” egenskaper för tydlighet i CSV och rapport
# "sam" = Security account manager (branch förkortning)
# Väljer synliga kolumner och lägger till en beräknad kolumn för antal dagar inaktiv
Select-Object `
    samAccountName,
displayName,
department,
site,
lastLogon,
@{ Name = 'DaysInactive'; Expression = {
        # ((nu) - (sista inloggning)) ger ett TimeSpan-objekt
        # .Days ger heltalsdelen i dagar, räknar hur många hela dagar som har gått sedan sista inloggning
        ((Get-Date) - [datetime]$_.lastLogon).Days
    }
}

# =============================================================================
# 5) Räkna användare per avdelning (loop-varianten, “G-nivå”)

# Räkna antal användare per avdelning med enkel loop
# Vi gör detta i en egen, lättläst struktur ($usersPerDepartmentMap)


# HashTable (dict) där key = department-namn, value = räknare
# Skapar en tom tabell där nyckel är avdelning och värde är antal
$usersPerDepartmentMap = @{}

# Denna loop går igenom varje användare och ökar räknaren per avdelning

foreach ($userRecord in $data.users) {
    # $userRecord = "en rad" (ett användarobjekt) ur JSON-datan
    $deptName = $userRecord.department                                                  # Hämtar avdelningsnamn för aktuell användare
    if ([string]::IsNullOrWhiteSpace($deptName)) { $deptName = '(Okänd avdelning)' }    # Ersätter tomt värde med text som visar okänd avdelning

    if ($usersPerDepartmentMap.ContainsKey($deptName)) {    
        $usersPerDepartmentMap[$deptName] += 1      #   Ökar befintlig räknare eller startar på ett om avdelningen inte finns i tabellen
    }
    else {
        $usersPerDepartmentMap[$deptName] = 1
    }
}

# Visa resultatet i terminalen
# Skapa en liten tabell
# Denna sektion gör om tabellen till en lista av rader som är enkel att skriva ut
$usersPerDepartmentTable =
$usersPerDepartmentMap.GetEnumerator() |
ForEach-Object {
    # $_ = nuvarande Key/Value-par i hashtabellen
    # Denna rad bygger ett objekt med två kolumner department och count
    [pscustomobject]@{
        Department = $_.Key
        Count      = $_.Value
    }
} |
Sort-Object -Property Department # sorterar listan på avdelningsnamn så att utskriften blir stabil

# =============================================================================
# 6) Group-Object: datorer per site (pipeline-varianten)
 

# Detta visar hur man gör samma typ av gruppering fast PowerShell-igt
# Tar alla datorer gruppera per site välj namn och antal sortera på namn
# med Group-Object (och vi tar bara ut namn+antal).
$computersBySiteSummary =
$data.computers |
Group-Object -Property site |
Select-Object Name, Count |
Sort-Object -Property Name

 
# 7) Lösenordsålder per användare (dagar)
# =================================================


# Vi skapar en vy med DisplayName, PasswordLastSet och PasswordAgeDays.
# Denna sektion tar fram visningsnamn datum när lösenord sattes flagga för aldrig utgår samt ålder i dagar
$usersWithPasswordAge =
$data.users |
Select-Object `
    displayName,
passwordLastSet,
passwordNeverExpires,
@{ Name = 'PasswordAgeDays'; Expression = {
        ((Get-Date) - [datetime]$_.passwordLastSet).Days
    }
}

# =============================================================================
# 8) 10 datorer som inte checkat in på längst tid
 


# Tolkning: “Inte checkat in på längst tid” = äldst lastLogon först.
# Vi filtrerar normalt på enabled=true för att slippa RIP objekt.
# Filtrera till aktiva objekt sortera på äldst lastLogon och ta de första tio
$top10StaleComputers =
$data.computers |
Where-Object { $_.enabled -eq $true } |
Sort-Object @{Expression = { [datetime]$_.lastLogon }; Ascending = $true } |
Select-Object -First 10 `
    name, site, operatingSystem, operatingSystemVersion, lastLogon

# =============================================================================
# 9) Export: inactive_users.csv
 

# CSV med kolumnerna från $inactiveUsers ovan.
# -NoTypeInformation = snyggare CSV-rad 1
# -Encoding UTF8     = svenska tecken funkar i Excel
# -Delimiter ';'     = svensk Excel gillar semikolon
$inactiveCsvPath = Join-Path $outputDir 'inactive_users.csv'
$inactiveUsers |
Export-Csv -Path $inactiveCsvPath -NoTypeInformation -Encoding UTF8 -Delimiter ';'

 
# 10) Skapa TEXT-rapport (here-string) och spara
 
# VARFÖR here-string? Den gör det enkelt att skapa en flerradig textmall.
# Vi använder $() för att evaluera uttryck inuti strängen.

$report = @"

\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\
                         ACTIVE DIRECTORY AUDIT REPORT
///////////////////////////////////////////////////////////////////////////////

Generated: $($now.ToString("yyyy-MM-dd HH:mm:ss"))
Domain:    $domainName
Exported:  $($exportDate.ToString("yyyy-MM-dd HH:mm:ss"))
Users:     $totalUsers
Computers: $totalComputers

INACTIVE USERS (>= 30 days)
________________________________________________________________________________________________________________________________________________________________________________________________________________________
SAM_AccountName               DisplayName                   Dept                          Site                          DaysInactive
________________________________________________________________________________________________________________________________________________________________________________________________________________________
"@

# Lägg till en rad från $inactiveUsers för varje inaktiv användare i rapporten
foreach ($u in $inactiveUsers) {
    # $u = ett objekt med egenskaperna vi valde i Select-Object
    $report += ("{0,-30}{1,-30}{2,-30}{3,-30}{4,5}" -f `
            $u.samAccountName, $u.displayName, $u.department, $u.site, $u.DaysInactive) + "`r`n"
}

$report += @"

USERS PER DEPARTMENT (loop-count)
________________________________________________________________________________________________________________________________________________________________________________________________________________________
Department                    Count
________________________________________________________________________________________________________________________________________________________________________________________________________________________
"@

foreach ($row in $usersPerDepartmentTable) {
    $report += ("{0,-30}{1,5}" -f $row.Department, $row.Count) + "`r`n"
}

$report += @"

COMPUTERS BY SITE (Group-Object)
________________________________________________________________________________________________________________________________________________________________________________________________________________________
Site                          Count
________________________________________________________________________________________________________________________________________________________________________________________________________________________
"@

foreach ($row in $computersBySiteSummary) {
    $report += ("{0,-30}{1,5}" -f $row.Name, $row.Count) + "`r`n"
}

$report += @"

TOP 10 STALE COMPUTERS (oldest lastLogon among enabled)
__________________________________________________________________________________________________________________________________________________________________________________________________________________________
Name                 Site             OS                  Version                    LastLogon
________________________________________________________________________________________________________________________________________________________________________________________________________________________
"@

# Denna loop skriver en rad per dator och formaterar datumet för läsbarhet
foreach ($c in $top10StaleComputers) {
    $report += ("{0,-20}{1,-16}{2,-24}{3,-20}{4}" -f `
            $c.name, $c.site, $c.operatingSystem, $c.operatingSystemVersion,
        ([datetime]$c.lastLogon).ToString("yyyy-MM-dd HH:mm")) + "`r`n"
}


$report += @"

TOP 10 OLDEST PASSWORDS (PasswordAgeDays)
________________________________________________________________________________________________________________________________________________________________________________________________________________________
DisplayName                 PasswordLastSet               NeverExpires                  Age(Days)
________________________________________________________________________________________________________________________________________________________________________________________________________________________
"@

#   Sorterar på flest dagar tar de tio översta och lägger in rader i rapporten
$usersWithPasswordAge |
Sort-Object @{ Expression = { $_.PasswordAgeDays }; Descending = $true } |
Select-Object -First 10 |
ForEach-Object {
    $report += ("{0,-28}{1,-30}{2,-30}{3,9}" -f `
            $_.displayName,
        ([datetime]$_.passwordLastSet).ToString("yyyy-MM-dd"),
        $_.passwordNeverExpires,
        $_.PasswordAgeDays) + "`r`n"
}

# Spara rapporten
$reportPath = Join-Path $outputDir 'ad_report.txt'
$report | Out-File -FilePath $reportPath -Encoding UTF8

 
# 11) Konsol-summering (valfritt)
 

Write-Host "Klart! Resultat:"
Write-Host " - CSV: $inactiveCsvPath"
Write-Host " - Rapport: $reportPath"
