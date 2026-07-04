<#
    Uygulama Ã„Â°ndirme-GÃƒÂ¼ncelleme-SÃƒÂ¼rÃƒÂ¼cÃƒÂ¼ Yedek Alma-Temizleme AracÃ„Â±
    HazÃ„Â±rlayan: Mehmet IÃ…ÂIK
    GÃƒÂ¼ncelleme: 04.07.2026
    KullanÃ„Â±m: SaÃ„Å¸ tÃ„Â±k -> "PowerShell ile ÃƒÂ§alÃ„Â±Ã…Å¸tÃ„Â±r" veya yÃƒÂ¶netici PowerShell'de:
              powershell -ExecutionPolicy RemoteSigned -File "Bilgisayar_Araci.ps1"
    NOT: DosyayÃ„Â± "UTF-8 with BOM" olarak kaydedin (TÃƒÂ¼rkÃƒÂ§e + ÃƒÂ§erÃƒÂ§eve karakterleri iÃƒÂ§in).
#>

# ===================== YÃƒâ€“NETÃ„Â°CÃ„Â° KONTROLÃƒÅ“ + TEK PENCERE BAÃ…ÂLATMA =====================

function Test-Admin {
    $kimlik = [Security.Principal.WindowsIdentity]::GetCurrent()
    $rol = New-Object Security.Principal.WindowsPrincipal($kimlik)
    return $rol.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

# ================================================================
#  WINGET KURULUM BETIGI - Nihai Surum v2 (Sahaya Ozel)
#  Iyilestirmeler: Hata loglama + Dinamik UI.Xaml + Ag Dalgalanma Korumasi + LTSC Guncelleme
# ================================================================

# AÃ„Å¸ baÃ„Å¸lantÃ„Â±sÃ„Â± sorunlarÃ„Â±nÃ„Â± ÃƒÂ¶nlemek iÃƒÂ§in TLS 1.2'yi zorla (Eski sistemler iÃƒÂ§in kritik)
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

# ===================== LOGLAMA ALTYAPISI =====================
$Global:LogDosyasi = Join-Path $env:TEMP "winget-kurulum.log"

function Yaz-Log {
    param(
        [string]$Mesaj,
        [ValidateSet('BILGI','UYARI','HATA')]
        [string]$Seviye = 'BILGI'
    )
    $satir = "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')  [$Seviye]  $Mesaj"
    try { $satir | Out-File -FilePath $Global:LogDosyasi -Append -Encoding UTF8 } catch {}
}

Yaz-Log "==== Yeni kurulum oturumu baslatildi ===="

function Confirm-Islem {
    param([string]$Soru = "Bu iÃ…Å¸lemi yapmak istediÃ„Å¸inize emin misiniz?")
    Write-Host ""
    $cevap = Read-Host "  $Soru (E/H)"
    return ($cevap -eq "E" -or $cevap -eq "e")
}

# ===================== LTSC / LTSB TESPÃ„Â°TÃ„Â° =====================
function Test-LTSC {
    $editionId   = ""
    $productName = ""
    $sku         = -1

    try {
        $rk = Get-ItemProperty -Path "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion" -ErrorAction Stop
        $editionId   = "$($rk.EditionID)"
        $productName = "$($rk.ProductName)"
    } catch {
        Yaz-Log "Registry okunamadi (EditionID/ProductName): $($_.Exception.Message)" 'UYARI'
    }

    try {
        $os = Get-CimInstance Win32_OperatingSystem -ErrorAction Stop
        if ([string]::IsNullOrWhiteSpace($productName)) { $productName = "$($os.Caption)" }
        if ($null -ne $os.OperatingSystemSKU) { $sku = [int]$os.OperatingSystemSKU }
    } catch {
        Yaz-Log "CIM sorgusu basarisiz (Win32_OperatingSystem): $($_.Exception.Message)" 'UYARI'
    }

    $kural1 = ($editionId -match 'S$' -or $editionId -match 'SN$')
    $kural2 = ($productName -match 'LTSC' -or $productName -match 'LTSB')
    $ltscSku = @(125, 126, 175, 164)
    $kural3  = ($ltscSku -contains $sku)

    $sonuc = [bool]($kural1 -or $kural2 -or $kural3)
    Yaz-Log "LTSC tespiti -> EditionID='$editionId' ProductName='$productName' SKU=$sku Sonuc=$sonuc"
    return $sonuc
}

# ===================== ZAMAN AÃ…ÂIMLI Ãƒâ€¡ALIÃ…ÂTIRMA YARDIMCISI =====================
function Invoke-ZamanAsimli {
    param([scriptblock]$Kod, [int]$Saniye = 180)
    $job = Start-Job -ScriptBlock $Kod
    $beklemeSonucu = Wait-Job $job -Timeout $Saniye

    if ($beklemeSonucu) {
        $durum = $job.State
        Receive-Job $job -ErrorAction SilentlyContinue | Out-Null
        Remove-Job $job -Force -ErrorAction SilentlyContinue
        Yaz-Log "Zaman asimli is tamamlandi. Durum=$durum"
        return ($durum -eq 'Completed')
    } else {
        Stop-Job $job -ErrorAction SilentlyContinue
        Remove-Job $job -Force -ErrorAction SilentlyContinue
        Yaz-Log "Zaman asimli is ZAMAN ASIMINA ugradi ($Saniye sn)." 'UYARI'
        return $false
    }
}

# ===================== DOSYA Ã„Â°NDÃ„Â°RME YARDIMCISI (Yeniden Deneme KorumalÃ„Â±) =====================
function Indir-Dosya {
    param(
        [string]$Url, 
        [string]$Hedef, 
        [int]$Timeout = 60,
        [int]$MaksimumDeneme = 3,
        [int]$SaniyeBekle = 5
    )
    
    $deneme = 0
    $basarili = $false
    $eski = $ProgressPreference
    $ProgressPreference = 'SilentlyContinue'

    while ($deneme -lt $MaksimumDeneme -and -not $basarili) {
        $deneme++
        try {
            Invoke-WebRequest -Uri $Url -OutFile $Hedef -UseBasicParsing -TimeoutSec $Timeout -ErrorAction Stop
            Yaz-Log "Indirme basarili: $Url (Deneme: $deneme)"
            $basarili = $true
        } catch {
            $hataMesaji = $_.Exception.Message
            if ($deneme -lt $MaksimumDeneme) {
                Write-Host "        [$deneme/$MaksimumDeneme] Ag dalgalanmasi: $Url ($SaniyeBekle sn sonra tekrar denenecek)" -ForegroundColor DarkYellow
                Yaz-Log "Indirme kesintiye ugradi: $Url -> $hataMesaji | $SaniyeBekle saniye icinde tekrar deneniyor... (Deneme: $deneme/$MaksimumDeneme)" 'UYARI'
                Start-Sleep -Seconds $SaniyeBekle
            } else {
                Yaz-Log "Indirme BASARISIZ: $Url -> $hataMesaji | Maksimum deneme sayisina ulasildi." 'HATA'
            }
        }
    }

    $ProgressPreference = $eski
    return $basarili
}

# ===================== NUGET SÃƒÅ“RÃƒÅ“M SORGUSU =====================
function Get-NuGetSonKararli {
    param([string]$Aile)
    try {
        $api = "https://api.nuget.org/v3-flatcontainer/microsoft.ui.xaml/index.json"
        $liste = Invoke-RestMethod -Uri $api -UseBasicParsing -TimeoutSec 30 -ErrorAction Stop
        $kararli = $liste.versions | Where-Object { $_ -notmatch '-' }
        if ($Aile) {
            $desen = '^' + [regex]::Escape($Aile) + '\.\d+$'
            $kararli = $kararli | Where-Object { $_ -match $desen }
        }
        $son = $kararli | Sort-Object { [version]$_ } | Select-Object -Last 1
        return $son
    } catch {
        Yaz-Log "Get-NuGetSonKararli hatasi: $($_.Exception.Message)" 'UYARI'
        return $null
    }
}

# ===================== UI.XAML TAMAMEN DÃ„Â°NAMÃ„Â°K Ãƒâ€¡Ãƒâ€“ZÃƒÅ“M =====================
function Get-UIXamlBilgisi {
    param([string]$WingetMsixYolu)

    $sonuc = [ordered]@{
        Aile       = "2.8"
        NuGetSurum = "2.8.6"
        Kaynak     = "yedek"
    }

    if ($WingetMsixYolu -and (Test-Path $WingetMsixYolu)) {
        try {
            $cikart = Join-Path $env:TEMP "winget_manifest_check"
            if (Test-Path $cikart) { Remove-Item $cikart -Recurse -Force -ErrorAction SilentlyContinue }
            $zipKopya = "$WingetMsixYolu.zip"
            Copy-Item $WingetMsixYolu $zipKopya -Force
            Expand-Archive -Path $zipKopya -DestinationPath $cikart -Force -ErrorAction Stop

            $manifestler = Get-ChildItem -Path $cikart -Recurse -Filter "AppxManifest.xml" -ErrorAction SilentlyContinue
            if (-not $manifestler) {
                $icPaketler = Get-ChildItem -Path $cikart -Recurse -Include "*.msix","*.appx" -ErrorAction SilentlyContinue
                foreach ($ic in $icPaketler) {
                    try {
                        $icZip = "$($ic.FullName).zip"; Copy-Item $ic.FullName $icZip -Force
                        $icDir = Join-Path $cikart ("ic_" + $ic.BaseName)
                        Expand-Archive -Path $icZip -DestinationPath $icDir -Force -ErrorAction Stop
                    } catch {}
                }
                $manifestler = Get-ChildItem -Path $cikart -Recurse -Filter "AppxManifest.xml" -ErrorAction SilentlyContinue
            }

            foreach ($mf in $manifestler) {
                [xml]$xml = Get-Content $mf.FullName -ErrorAction Stop
                $bagimliliklar = $xml.Package.Dependencies.PackageDependency
                foreach ($dep in $bagimliliklar) {
                    if ($dep.Name -like "Microsoft.UI.Xaml*") {
                        $ad = $dep.Name
                        $aile = ($ad -replace '^Microsoft\.UI\.Xaml\.', '')
                        $sonuc.Aile = $aile
                        $nu = Get-NuGetSonKararli -Aile $aile
                        if ($nu) { $sonuc.NuGetSurum = $nu }
                        $sonuc.Kaynak = "manifest"
                        Yaz-Log "UI.Xaml manifestten cozuldu: Aile=$aile NuGetSurum=$($sonuc.NuGetSurum)"
                        Remove-Item $zipKopya -Force -ErrorAction SilentlyContinue
                        Remove-Item $cikart -Recurse -Force -ErrorAction SilentlyContinue
                        return $sonuc
                    }
                }
            }
            Remove-Item $zipKopya -Force -ErrorAction SilentlyContinue
            Remove-Item $cikart -Recurse -Force -ErrorAction SilentlyContinue
        } catch {
            Yaz-Log "Manifest okuma basarisiz: $($_.Exception.Message)" 'UYARI'
        }
    }

    try {
        $enSon = Get-NuGetSonKararli
        if ($enSon) {
            $sonuc.NuGetSurum = $enSon
            $sonuc.Aile = ($enSon -split '\.')[0..1] -join '.'
            $sonuc.Kaynak = "nuget-enguncel"
            Yaz-Log "UI.Xaml NuGet en guncel kararli: $enSon (Aile=$($sonuc.Aile))"
            return $sonuc
        }
    } catch {
        Yaz-Log "NuGet en guncel sorgusu basarisiz: $($_.Exception.Message)" 'UYARI'
    }

    Yaz-Log "UI.Xaml icin yedek sabit kullanildi: $($sonuc.NuGetSurum)" 'UYARI'
    return $sonuc
}

# ===================== GEÃƒâ€¡Ã„Â°CÃ„Â° DOSYA TEMÃ„Â°ZLÃ„Â°Ã„ÂÃ„Â° =====================
function Temizle-GeciciDosyalar {
    $tmp = $env:TEMP
    $hedefler = @(
        "vclibs_x64.appx", "vclibs_arm64.appx",
        "uixaml.zip", "uixaml_extract",
        "appinst.msixbundle", "appinst.msixbundle.zip",
        "winget_manifest_check",
        "license.xml", "getwinget.msixbundle"
    )
    foreach ($ad in $hedefler) {
        $yol = Join-Path $tmp $ad
        if (Test-Path $yol) {
            try { Remove-Item $yol -Recurse -Force -ErrorAction Stop; Yaz-Log "Gecici dosya silindi: $ad" }
            catch { Yaz-Log "Gecici dosya silinemedi: $ad  ->  $($_.Exception.Message)" 'UYARI' }
        }
    }
}

# ===================== LTSC GÃƒÅ“NCELLEME GÃƒâ€“REVÃ„Â° =====================
function Kur-WingetLTSCGuncellemeGorevi {
    $GorevAdi = "Winget-OtomatikGuncelleme-LTSC"
    Write-Host "        LTSC otomatik gÃƒÂ¼ncelleme gÃƒÂ¶revi ayarlanÃ„Â±yor..." -ForegroundColor DarkGray
    Yaz-Log "LTSC guncelleme gorevi olusturma baslatildi."

    try {
        Unregister-ScheduledTask -TaskName $GorevAdi -Confirm:$false -ErrorAction SilentlyContinue

        $tetikleyici = New-ScheduledTaskTrigger -Weekly -DaysOfWeek Friday -At 12:00pm
        $psKomut = "Install-PackageProvider -Name NuGet -Force -Scope CurrentUser -ErrorAction SilentlyContinue; Set-PSRepository -Name PSGallery -InstallationPolicy Trusted -ErrorAction SilentlyContinue; Install-Script -Name winget-install -Force -Scope CurrentUser -ErrorAction SilentlyContinue; `$p = (Get-InstalledScript winget-install).InstalledLocation; & (Join-Path `$p 'winget-install.ps1') -Force"
        
        $eylem = New-ScheduledTaskAction -Execute "powershell.exe" -Argument "-WindowStyle Hidden -NonInteractive -NoProfile -Command `"$psKomut`""

        Register-ScheduledTask -TaskName $GorevAdi -Trigger $tetikleyici -Action $eylem -Description "LTSC sistemlerde Winget'i guncel tutmak icin haftalik kontrol yapar." -ErrorAction Stop | Out-Null
        
        Yaz-Log "LTSC guncelleme gorevi basariyla kaydedildi."
    } catch {
        Write-Host "        GÃƒÂ¼ncelleme gÃƒÂ¶revi oluÃ…Å¸turulamadÃ„Â±!" -ForegroundColor Red
        Yaz-Log "LTSC guncelleme gorevi olusturma HATASI: $($_.Exception.Message)" 'HATA'
    }
}

# ===================== MANUEL YOL 2 (VCLibs + UI.Xaml + App Installer) =====================
function Install-WingetManuel {
    Write-Host "  [Yedek Yol] Manuel bagimlilik kurulumu deneniyor..." -ForegroundColor DarkGray
    Yaz-Log "Manuel yedek yol basladi."
    
    $mimari = if ($env:PROCESSOR_ARCHITECTURE -eq "ARM64") { "arm64" } else { "x64" }
    $tmp = $env:TEMP

    try {
        $sk = "HKLM:\SOFTWARE\Policies\Microsoft\Windows\Appx"
        if (-not (Test-Path $sk)) { New-Item -Path $sk -Force | Out-Null }
        New-ItemProperty -Path $sk -Name "AllowAllTrustedApps" -PropertyType DWord -Value 1 -Force -ErrorAction Stop | Out-Null
        Yaz-Log "Sideload politikasi ayarlandi."
    } catch { Yaz-Log "Sideload ayarlanamadi: $($_.Exception.Message)" 'UYARI' }

    Write-Host "        VCLibs ($mimari)..." -ForegroundColor DarkGray
    $vclibs = Join-Path $tmp "vclibs_$mimari.appx"
    if (Indir-Dosya "https://aka.ms/Microsoft.VCLibs.$mimari.14.00.Desktop.appx" $vclibs 60) {
        try { Add-AppxPackage -Path $vclibs -ErrorAction Stop; Yaz-Log "VCLibs kuruldu." }
        catch { Yaz-Log "VCLibs kurulum hatasi: $($_.Exception.Message)" 'HATA' }
    }

    $appinst = Join-Path $tmp "appinst.msixbundle"
    $license = Join-Path $tmp "license.xml"
    $appIndirildi = $false
    try {
        $rel = Invoke-RestMethod -Uri "https://api.github.com/repos/microsoft/winget-cli/releases/latest" -UseBasicParsing -TimeoutSec 60 -ErrorAction Stop
        $msix = $rel.assets | Where-Object { $_.name -like "*.msixbundle" } | Select-Object -First 1
        $lic  = $rel.assets | Where-Object { $_.name -like "*License1.xml" } | Select-Object -First 1
        if ($msix) { $appIndirildi = Indir-Dosya $msix.browser_download_url $appinst 120 }
        if ($lic)  { Indir-Dosya $lic.browser_download_url $license 60 | Out-Null }
    } catch { Yaz-Log "GitHub Release alinamadi." 'UYARI' }
    
    if (-not $appIndirildi) {
        Yaz-Log "GitHub yolu tutmadi, aka.ms deneniyor." 'UYARI'
        $appIndirildi = Indir-Dosya "https://aka.ms/getwinget" $appinst 120
    }

    $xamlBilgi = Get-UIXamlBilgisi -WingetMsixYolu $(if ($appIndirildi) { $appinst } else { $null })
    $zatenVar = Get-AppxPackage -Name ("Microsoft.UI.Xaml." + $xamlBilgi.Aile + "*") -ErrorAction SilentlyContinue
    if (-not $zatenVar) {
        Write-Host "        UI.Xaml ($($xamlBilgi.NuGetSurum))..." -ForegroundColor DarkGray
        $nupkg = Join-Path $tmp "uixaml.zip"; $xamlDir = Join-Path $tmp "uixaml_extract"
        if (Indir-Dosya "https://www.nuget.org/api/v2/package/Microsoft.UI.Xaml/$($xamlBilgi.NuGetSurum)" $nupkg 60) {
            try {
                if (Test-Path $xamlDir) { Remove-Item $xamlDir -Recurse -Force -ErrorAction SilentlyContinue }
                Expand-Archive -Path $nupkg -DestinationPath $xamlDir -Force -ErrorAction Stop
                $xa = Get-ChildItem -Path $xamlDir -Recurse -Filter "*.appx" | Where-Object { $_.FullName -match "\\$mimari\\" } | Select-Object -First 1
                if ($xa) { Add-AppxPackage -Path $xa.FullName -ErrorAction Stop; Yaz-Log "UI.Xaml kuruldu." }
            } catch { Yaz-Log "UI.Xaml kurulum hatasi." 'HATA' }
        }
    } else { Yaz-Log "UI.Xaml zaten kurulu." }

    Write-Host "        App Installer kuruluyor..." -ForegroundColor DarkGray
    $lisansli = $false
    if ($appIndirildi -and (Test-Path $license)) {
        $ap = $appinst; $lp = $license
        $lisansli = Invoke-ZamanAsimli -Saniye 120 -Kod { Add-AppxProvisionedPackage -Online -PackagePath $using:ap -LicensePath $using:lp -ErrorAction Stop | Out-Null }
    }
    if (-not $lisansli -and $appIndirildi) {
        $ap2 = $appinst
        Invoke-ZamanAsimli -Saniye 120 -Kod { Add-AppxPackage -Path $using:ap2 -ErrorAction SilentlyContinue } | Out-Null
    }
}

# ===================== WINGET KURULUM ANA FONKSÃ„Â°YONU =====================
function Install-Winget {
    param([switch]$Sessiz)
    
    if (-not $Sessiz) { Write-Host "Winget durumu kontrol ediliyor..." -ForegroundColor Cyan }
    if (Get-Command winget -ErrorAction SilentlyContinue) {
        if (-not $Sessiz) { Write-Host "Winget bu sistemde zaten kurulu!" -ForegroundColor Green }
        Yaz-Log "Winget zaten kurulu."
        
        # Zaten kuruluysa LTSC ise yine de gÃƒÂ¶rev atayalÃ„Â±m (ÃƒÂ¶nceden kurulmuÃ…Å¸ ama gÃƒÂ¶rev atÃ„Â±lmamÃ„Â±Ã…Å¸ olabilir)
        if (Test-LTSC) { Kur-WingetLTSCGuncellemeGorevi }
        return $true
    }
Write-Host ""
    Write-Host "  Sistemde Winget (Windows Paket YÃƒÂ¶neticisi) bulunamadÃ„Â±." -ForegroundColor Yellow
    Write-Host "  Uygulama indirme ve gÃƒÂ¼ncelleme menÃƒÂ¼lerinin ÃƒÂ§alÃ„Â±Ã…Å¸masÃ„Â± iÃƒÂ§in gereklidir." -ForegroundColor DarkGray
    if (-not (Confirm-Islem "Winget Ã…Å¸imdi kurulsun mu?")) {
        Write-Host "  Winget kurulumu atlandÃ„Â±. Winget gerektiren menÃƒÂ¼ler ÃƒÂ§alÃ„Â±Ã…Å¸mayacaktÃ„Â±r." -ForegroundColor Red
        Yaz-Log "Winget kurulumu kullanÃ„Â±cÃ„Â± tarafÃ„Â±ndan iptal edildi." 'UYARI'
        Start-Sleep -Seconds 2
        return $false
    }
    Write-Host "Sistem mimarisi inceleniyor..." -ForegroundColor Cyan
    $ltsc = Test-LTSC

    if ($ltsc) {
        Write-Host "SÃ„Â°STEM TESPÃ„Â°TÃ„Â°: LTSC / LTSB SÃƒÂ¼rÃƒÂ¼mÃƒÂ¼!" -ForegroundColor Yellow
        Write-Host "Ãƒâ€“zel LTSC yÃƒÂ¶ntemi (PSGallery) baÃ…Å¸latÃ„Â±lÃ„Â±yor..." -ForegroundColor DarkGray

        try {
            $basarili = Invoke-ZamanAsimli -Saniye 240 -Kod {
                Install-PackageProvider -Name NuGet -Force -Scope CurrentUser -ErrorAction SilentlyContinue | Out-Null
                Set-PSRepository -Name PSGallery -InstallationPolicy Trusted -ErrorAction SilentlyContinue
                Install-Script -Name winget-install -Force -Scope CurrentUser -ErrorAction Stop
                $p = (Get-InstalledScript winget-install -ErrorAction Stop).InstalledLocation
                & (Join-Path $p "winget-install.ps1") -Force
            }
            if (-not $basarili) {
                Write-Host "LTSC birincil yolu (PSGallery) tamamlanamadi." -ForegroundColor Red
                Yaz-Log "LTSC PSGallery yolu tamamlanamadi." 'HATA'
            } else {
                # --- GÃƒÅ“NCELLEME GÃƒâ€“REVÃ„Â° BURADA Ãƒâ€¡AÃ„ÂRILIYOR ---
                Kur-WingetLTSCGuncellemeGorevi
            }
        } catch {
            Write-Host "LTSC kurulumu sirasinda hata." -ForegroundColor Red
            Yaz-Log "LTSC kurulum istisnasi: $($_.Exception.Message)" 'HATA'
        }

    } else {
        Write-Host "SÃ„Â°STEM TESPÃ„Â°TÃ„Â°: Standart Windows SÃƒÂ¼rÃƒÂ¼mÃƒÂ¼." -ForegroundColor Green
        Write-Host "Normal kurulum (App Installer) baÃ…Å¸latÃ„Â±lÃ„Â±yor..." -ForegroundColor DarkGray
        
        # Indir-Dosya kullanÃ„Â±larak standart indirme daha gÃƒÂ¼venli hale getirildi
        $getwinget = Join-Path $env:TEMP "getwinget.msixbundle"
        if (Indir-Dosya "https://aka.ms/getwinget" $getwinget 120) {
            try { Add-AppxPackage -Path $getwinget -ErrorAction Stop; Yaz-Log "Standart paket kuruldu." }
            catch { Yaz-Log "Standart kurulum hatasi: $($_.Exception.Message)" 'HATA' }
        }
    }

    Start-Sleep -Seconds 3
    if (Get-Command winget -ErrorAction SilentlyContinue) {
        Write-Host "Ã„Â°Ã…Å¸lem TamamlandÃ„Â±: Winget baÃ…Å¸arÃ„Â±yla kuruldu (birincil yol)!" -ForegroundColor Green
        Temizle-GeciciDosyalar
        return $true
    }

    Write-Host "Birincil yol sonuc vermedi -> manuel yedek yola geciliyor..." -ForegroundColor DarkYellow
    Install-WingetManuel

    Start-Sleep -Seconds 3
    Temizle-GeciciDosyalar

    if (Get-Command winget -ErrorAction SilentlyContinue) {
        Write-Host "Ã„Â°Ã…Å¸lem TamamlandÃ„Â±: Winget baÃ…Å¸arÃ„Â±yla kuruldu (manuel yedek yol)!" -ForegroundColor Green
        if ($ltsc) { Kur-WingetLTSCGuncellemeGorevi } # Manuel yolla kurulduysa ve LTSC ise gÃƒÂ¶rev ata
        return $true
    } else {
        Write-Host "Ã„Â°Ã…Å¸lem BaÃ…Å¸arÃ„Â±sÃ„Â±z: Winget kurulamadÃ„Â±. Log: $Global:LogDosyasi" -ForegroundColor Red
        return $false
    }
}

# BetiÃ„Å¸in indirileceÃ„Å¸i adres (yalnÃ„Â±zca yerel dosya yoksa yedek olarak kullanÃ„Â±lÃ„Â±r)
$ScriptUrl = "https://raw.githubusercontent.com/mhmtsk44/bilgisayar-araci/refs/heads/main/Bilgisayar_Araci.ps1"

# Ãƒâ€¡alÃ„Â±Ã…Å¸an betiÃ„Å¸in tam yolu (yÃƒÂ¶netici/terminal yÃƒÂ¼kseltmesinde AYNI dosya yeniden ÃƒÂ§alÃ„Â±Ã…Å¸Ã„Â±r)
$BetikYolu = $PSCommandPath
if ([string]::IsNullOrWhiteSpace($BetikYolu)) { $BetikYolu = $MyInvocation.MyCommand.Path }

# YÃƒÂ¼kseltme komutunu ÃƒÂ¼ret: yerel dosya varsa onu ÃƒÂ§alÃ„Â±Ã…Å¸tÃ„Â±r, yoksa indir
function Get-BaslatmaKomutu {
    if (-not [string]::IsNullOrWhiteSpace($BetikYolu) -and (Test-Path $BetikYolu)) {
        # GÃƒÅ“VENLÃ„Â°: incelenen yerel dosyanÃ„Â±n kendisi ÃƒÂ§alÃ„Â±Ã…Å¸Ã„Â±r, offline da ÃƒÂ§alÃ„Â±Ã…Å¸Ã„Â±r
        return @{ Tip = "Dosya"; Deger = $BetikYolu }
    } else {
        # YEDEK: yerel dosya yoksa (ÃƒÂ¶rn. irm ile ÃƒÂ§aÃ„Å¸rÃ„Â±ldÃ„Â±ysa) uzaktan indir
        return @{ Tip = "Komut"; Deger = "irm '$ScriptUrl' | iex" }
    }
}

# AÃ…ÂAMA 1: YÃƒÂ¶netici deÃ„Å¸ilsek -> yÃƒÂ¶netici olarak yeniden baÃ…Å¸lat
if (-not (Test-Admin)) {
    Write-Host "YÃƒÂ¶netici izniyle yeniden baÃ…Å¸latÃ„Â±lÃ„Â±yor..." -ForegroundColor Yellow
    $bk = Get-BaslatmaKomutu
    try {
        if ($bk.Tip -eq "Dosya") {
            Start-Process powershell -ArgumentList "-ExecutionPolicy Bypass -File `"$($bk.Deger)`"" -Verb RunAs -ErrorAction Stop
        } else {
            # UZAKTAN (irm|iex) MOD: -NoExit eklendi ki hata olsa da pencere kapanmasÃ„Â±n
            Start-Process powershell -ArgumentList "-NoExit -ExecutionPolicy Bypass -Command `"$($bk.Deger)`"" -Verb RunAs -ErrorAction Stop
        }
    } catch {
        Write-Host ""
        Write-Host "HATA: YÃƒÂ¶netici izni verilmedi veya yÃƒÂ¼kseltme baÃ…Å¸arÃ„Â±sÃ„Â±z oldu." -ForegroundColor Red
        Write-Host "AyrÃ„Â±ntÃ„Â±: $($_.Exception.Message)" -ForegroundColor DarkYellow
        Write-Host ""
        Read-Host "Kapatmak iÃƒÂ§in Enter'a basÃ„Â±n"
    }
    exit
}

# AÃ…ÂAMA 1.5: Winget'i garantiye al (-Sessiz parametresiyle, ekranda yazÃ„Â± kalabalÃ„Â±Ã„Å¸Ã„Â± yapmaz)
$WingetVar = Install-Winget -Sessiz

# ===================== AÃ…ÂAMA 2: WINDOWS TERMINAL'DE AÃƒâ€¡ (gÃƒÂ¼venli, dÃƒÂ¶ngÃƒÂ¼sÃƒÂ¼z) =====================
if ((-not $env:WT_SESSION) -and ($env:BILGISAYAR_ARACI_WT -ne "1")) {

    $wt = Get-Command wt.exe -ErrorAction SilentlyContinue
    if (-not $wt) {
        $wtPath = "$env:LOCALAPPDATA\Microsoft\WindowsApps\wt.exe"
        if (Test-Path $wtPath) { $wt = $wtPath }
    }

    if ($wt) {
        $bk = Get-BaslatmaKomutu
        try {
            if ($bk.Tip -eq "Dosya") {
                # DÃƒÂ¶ngÃƒÂ¼ bayraÃ„Å¸Ã„Â±nÃ„Â± Ãƒâ€“NCEDEN bu pencerede ayarla; yeni pencere miras alÃ„Â±r
                [Environment]::SetEnvironmentVariable("BILGISAYAR_ARACI_WT", "1", "Process")
                # -File ile ÃƒÂ§alÃ„Â±Ã…Å¸tÃ„Â±r: yol boÃ…Å¸luk iÃƒÂ§erse bile gÃƒÂ¼venli
                Start-Process wt.exe -ArgumentList @(
                    "powershell", "-NoExit", "-ExecutionPolicy", "Bypass",
                    "-File", "`"$($bk.Deger)`""
                ) -ErrorAction Stop
            } else {
                Start-Process wt.exe -ArgumentList @(
                    "powershell", "-NoExit", "-ExecutionPolicy", "Bypass",
                    "-Command", "`"$($bk.Deger)`""
                ) -ErrorAction Stop
            }
            exit   # wt aÃƒÂ§Ã„Â±ldÃ„Â± -> baÃ…Å¸latÃ„Â±cÃ„Â± pencereyi kapat
        } catch {
            # wt aÃƒÂ§Ã„Â±lamadÃ„Â± -> bu pencerede devam et
        }
    }
}

# ===================== TEMEL AYARLAR =====================
$ErrorActionPreference = "Continue"
$Host.UI.RawUI.WindowTitle = "Bilgisayar AracÃ„Â± - Mehmet IÃ…ÂIK"
try { [Console]::OutputEncoding = [System.Text.Encoding]::UTF8 } catch {}

if ($Host.Name -eq 'ConsoleHost') {
    try {
        $raw = $Host.UI.RawUI
        $max = $raw.MaxPhysicalWindowSize
        $genislik = [math]::Min(120, $max.Width)
        $yukseklik = [math]::Min(46, $max.Height)
        $raw.BufferSize = New-Object Management.Automation.Host.Size($genislik, 3000)
        $raw.WindowSize = New-Object Management.Automation.Host.Size($genislik, $yukseklik)
    } catch {}
}

try { $Host.UI.RawUI.BackgroundColor = "Black"; $Host.UI.RawUI.ForegroundColor = "Gray"; Clear-Host } catch {}

# ===================== MODERN TEMA / RENK PALETÃ„Â° =====================
$Tema = @{
    Cerceve  = "DarkCyan"
    Vurgu    = "Cyan"
    Metin    = "Gray"
    Baslik   = "White"
    Basari   = "Green"
    Hata     = "Red"
    Soluk    = "DarkGray"
}
# ===================== MODERN Ãƒâ€¡ERÃƒâ€¡EVE =====================
$BoxWidth = 78
function Show-Top    { Write-Host ("Ã¢â€¢â€" + ("Ã¢â€¢Â" * $BoxWidth) + "Ã¢â€¢â€”") -ForegroundColor $Tema.Cerceve }
function Show-Bottom { Write-Host ("Ã¢â€¢Å¡" + ("Ã¢â€¢Â" * $BoxWidth) + "Ã¢â€¢Â") -ForegroundColor $Tema.Cerceve }
function Show-Divider{ Write-Host ("Ã¢â€¢Å¸" + ("Ã¢â€â‚¬" * $BoxWidth) + "Ã¢â€¢Â¢") -ForegroundColor $Tema.Cerceve }
function Show-Line {
    param([string]$Metin, [string]$Renk = $Tema.Metin)
    
    # Ã¢Å“Â¨ emojisi 1 karakter gÃƒÂ¶rÃƒÂ¼nÃƒÂ¼r ama ekranda 2 birim yer kaplar. 
    # HesabÃ„Â± dÃƒÂ¼zeltmek iÃƒÂ§in 'Ã¢Å“Â¨' yerine geÃƒÂ§ici olarak iki nokta '..' saydÃ„Â±rÃ„Â±yoruz.
    $sanalUzunluk = ($Metin -replace 'Ã¢Å“Â¨', '..').Length

    $temiz = $Metin
    if ($sanalUzunluk -gt $BoxWidth) { $temiz = $temiz.Substring(0, $BoxWidth) }
    $bosluk = [math]::Max(1, $BoxWidth - $sanalUzunluk)
    
    Write-Host "Ã¢â€¢â€˜" -ForegroundColor $Tema.Cerceve -NoNewline
    Write-Host (" " + $temiz + (" " * ($bosluk - 1))) -ForegroundColor $Renk -NoNewline
    Write-Host "Ã¢â€¢â€˜" -ForegroundColor $Tema.Cerceve
}

function Show-Header {
    param([string]$Baslik)
    Clear-Host
    Show-Top
    Show-Line "  ÄŸÅ¸â€™Â» BÃ„Â°LGÃ„Â°SAYAR YÃƒâ€“NETÃ„Â°M ARACI" $Tema.Soluk
    Show-Line "  Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬" $Tema.Soluk  # Ã„Â°nce bir ayraÃƒÂ§
    Show-Line "  Ã¢Å“Â¨ $Baslik" $Tema.Vurgu
    Show-Bottom
    Write-Host ""
}

function Write-Result {
    param(
        $Basari,
        $Mesaj = ""
    )

    # --- AKILLI PARAMETRE ALGILAMA (iki ÃƒÂ§aÃ„Å¸rÃ„Â± stilini de destekler) ---
    #   DOÃ„ÂRU:  Write-Result $true "mesaj"      (bool, string)
    #   ESKÃ„Â°:   Write-Result $true "mesaj"       (string, bool)  Ã¢â€ Â otomatik dÃƒÂ¼zeltilir
    # EÃ„Å¸er $Basari bool DEÃ„ÂÃ„Â°L ama $Mesaj bool ise, parametreler ters gelmiÃ…Å¸tir Ã¢â€ â€™ yer deÃ„Å¸iÃ…Å¸tir.
    if (($Basari -isnot [bool]) -and ($Mesaj -is [bool])) {
        $gecici = $Basari
        $Basari = $Mesaj
        $Mesaj  = $gecici
    }

    # --- Basari deÃ„Å¸erini gÃƒÂ¼venli Ã…Å¸ekilde Boolean'a ÃƒÂ§evir ---
    $durum = $false
    try {
        if ($Basari -is [bool]) {
            $durum = $Basari
        } elseif ($Basari -is [int] -or $Basari -is [long]) {
            $durum = ([int]$Basari -eq 1)
        } else {
            $metin = "$Basari".Trim().ToLower()
            $durum = ($metin -eq 'true' -or $metin -eq '1')
        }
    } catch {
        $durum = $false
    }

    # $Mesaj'Ã„Â± her zaman metne ÃƒÂ§evir (bool geldiyse bile gÃƒÂ¼venli)
    $mesajMetni = "$Mesaj"

    if ($durum) {
        Write-Host "  Ã¢Å“â€œ  $mesajMetni" -ForegroundColor $Tema.Basari
    } else {
        Write-Host "  Ã¢Å“â€”  $mesajMetni" -ForegroundColor $Tema.Hata
    }
}

# ===================== WINGET BÃ„Â°LGÃ„Â°LENDÃ„Â°RME EKRANI =====================
function Show-WingetHelp {
    Show-Header "WINGET (PAKET YÃƒâ€“NETÃ„Â°CÃ„Â°SÃ„Â°) BULUNAMADI"

    Write-Host "  BilgisayarÃ„Â±nÃ„Â±zda Winget yÃƒÂ¼klÃƒÂ¼ deÃ„Å¸il." -ForegroundColor $Tema.Hata
    Write-Host ""
    Write-Host "  Winget, Windows 10 (1809+) ve Windows 11'de varsayÃ„Â±lan" -ForegroundColor $Tema.Metin
    Write-Host "  olarak gelen resmi bir paket yÃƒÂ¶neticisidir. YÃƒÂ¼klÃƒÂ¼ deÃ„Å¸ilse" -ForegroundColor $Tema.Metin
    Write-Host "  aÃ…Å¸aÃ„Å¸Ã„Â±daki yÃƒÂ¶ntemlerden biriyle kurabilirsiniz." -ForegroundColor $Tema.Metin
    Write-Host ("  " + ("-" * 74)) -ForegroundColor $Tema.Cerceve

    Write-Host "  YÃƒâ€“NTEM 1 Ã¢â‚¬â€ Microsoft Store (Ãƒâ€“nerilen)" -ForegroundColor $Tema.Vurgu
    Write-Host "   1) BaÃ…Å¸lat menÃƒÂ¼sÃƒÂ¼nden 'Microsoft Store' uygulamasÃ„Â±nÃ„Â± aÃƒÂ§Ã„Â±n." -ForegroundColor $Tema.Metin
    Write-Host "   2) Arama ÃƒÂ§ubuÃ„Å¸una 'Uygulama YÃƒÂ¼kleyici' yazÃ„Â±n." -ForegroundColor $Tema.Metin
    Write-Host "      (Ã„Â°ngilizce: 'App Installer')" -ForegroundColor $Tema.Soluk
    Write-Host "   3) 'Uygulama YÃƒÂ¼kleyici'yi bulun ve YÃƒÂ¼kle/GÃƒÂ¼ncelle deyin." -ForegroundColor $Tema.Metin
    Write-Host "   4) Kurulum bitince winget kullanÃ„Â±ma hazÃ„Â±r olur." -ForegroundColor $Tema.Metin
    Write-Host ""

    Write-Host "  YÃƒâ€“NTEM 2 Ã¢â‚¬â€ GeliÃ…Å¸tirici Modu ÃƒÂ¼zerinden" -ForegroundColor $Tema.Vurgu
    Write-Host "   1) BaÃ…Å¸lat > 'Ayarlar' uygulamasÃ„Â±nÃ„Â± aÃƒÂ§Ã„Â±n." -ForegroundColor $Tema.Metin
    Write-Host "   2) 'Gizlilik ve GÃƒÂ¼venlik' > 'GeliÃ…Å¸tiriciler iÃƒÂ§in' bÃƒÂ¶lÃƒÂ¼mÃƒÂ¼ne gidin." -ForegroundColor $Tema.Metin
    Write-Host "      (Win 10: 'GÃƒÂ¼ncelleme ve GÃƒÂ¼venlik' > 'GeliÃ…Å¸tiriciler iÃƒÂ§in')" -ForegroundColor $Tema.Soluk
    Write-Host "   3) 'GeliÃ…Å¸tirici Modu'nu aÃƒÂ§Ã„Â±n." -ForegroundColor $Tema.Metin
    Write-Host "   4) ArdÃ„Â±ndan Store'dan 'Uygulama YÃƒÂ¼kleyici'yi kurun." -ForegroundColor $Tema.Metin
    Write-Host ""

    Write-Host "  YÃƒâ€“NTEM 3 Ã¢â‚¬â€ Otomatik kurulum (bu araÃƒÂ§)" -ForegroundColor $Tema.Vurgu
    Write-Host "   Bu araÃƒÂ§ aÃƒÂ§Ã„Â±lÃ„Â±Ã…Å¸ta winget'i otomatik kurmayÃ„Â± dener." -ForegroundColor $Tema.Metin
    Write-Host "   BaÃ…Å¸arÃ„Â±sÃ„Â±z olduysa internet baÃ„Å¸lantÃ„Â±nÃ„Â±zÃ„Â± kontrol edip" -ForegroundColor $Tema.Metin
    Write-Host "   programÃ„Â± yeniden baÃ…Å¸latÃ„Â±n." -ForegroundColor $Tema.Metin
    Write-Host ""

    # KullanÃ„Â±cÃ„Â±yÃ„Â± doÃ„Å¸rudan Store'a yÃƒÂ¶nlendirme seÃƒÂ§eneÃ„Å¸i
    $ac = Read-Host "  Microsoft Store'da 'Uygulama YÃƒÂ¼kleyici' sayfasÃ„Â±nÃ„Â± aÃƒÂ§mak ister misiniz? (E/H)"
    if ($ac -eq "E" -or $ac -eq "e") {
        try {
            Start-Process "ms-windows-store://pdp/?productid=9NBLGGH4NNS1" -ErrorAction Stop
            Write-Result $true "Microsoft Store aÃƒÂ§Ã„Â±ldÃ„Â± (Uygulama YÃƒÂ¼kleyici sayfasÃ„Â±)."
        } catch {
            try {
                Start-Process "ms-windows-store://search/?query=Uygulama YÃƒÂ¼kleyici" -ErrorAction Stop
                Write-Result $true "Microsoft Store arama sayfasÃ„Â± aÃƒÂ§Ã„Â±ldÃ„Â±."
            } catch {
                Write-Result $false "Microsoft Store aÃƒÂ§Ã„Â±lamadÃ„Â±: $($_.Exception.Message)"
            }
        }
    } else {
        Write-Result $true "Store aÃƒÂ§Ã„Â±lmadÃ„Â±. Winget'i daha sonra kurabilirsiniz."
    }

    Write-Host ""
    Read-Host "  Devam etmek iÃƒÂ§in Enter'a basÃ„Â±n"
}

# ===================== WINGET KAYNAK GÃƒÅ“NCELLEME =====================
if ($WingetVar) {
    winget source update 2>$null | Out-Null
    if ($LASTEXITCODE -ne 0) {
        Write-Host "Uyari: winget kaynak guncellemesi tamamlanamadi." -ForegroundColor DarkYellow
    }
}

# ===================== YARDIMCI FONKSÃ„Â°YONLAR =====================
function Get-FolderSizeMB {
    param([string]$Yol)
    if (-not (Test-Path $Yol)) { return 0 }
    try {
        $dosyalar = Get-ChildItem -Path $Yol -Recurse -Force -File -ErrorAction SilentlyContinue
        if (-not $dosyalar) { return 0 }
        $olcum = $dosyalar | Measure-Object -Property Length -Sum
        if (-not $olcum.Sum) { return 0 }
        return [math]::Round($olcum.Sum / 1MB, 2)
    } catch { return 0 }
}

function Select-Folder {
    param([string]$Aciklama = "KlasÃƒÂ¶r seÃƒÂ§in")
    Add-Type -AssemblyName System.Windows.Forms
    $dlg = New-Object System.Windows.Forms.FolderBrowserDialog
    $dlg.Description = $Aciklama
    if ($dlg.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) { return $dlg.SelectedPath }
    return $null
}

function Select-File {
    param([string]$Filtre = "JSON DosyasÃ„Â± (*.json)|*.json|TÃƒÂ¼m Dosyalar (*.*)|*.*")
    Add-Type -AssemblyName System.Windows.Forms
    $dlg = New-Object System.Windows.Forms.OpenFileDialog
    $dlg.Filter = $Filtre
    if ($dlg.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) { return $dlg.FileName }
    return $null
}
# ===================== UYGULAMA LÃ„Â°STESÃ„Â° (dizi Ã¢â‚¬â€ sÃ„Â±ra %100 korunur) =====================

$Uygulamalar = @(
    @{ No = 1;  Ad = "Google Chrome";             Id = "Google.Chrome" }
    @{ No = 2;  Ad = "WinRAR";                    Id = "RARLab.WinRAR" }
    @{ No = 3;  Ad = "ACS Unified PC/SC Driver";  Id = "ACS.UnifiedPCSCDriver" }
    @{ No = 4;  Ad = "Adobe Reader";              Id = "Adobe.Acrobat.Reader.64-bit" }
    @{ No = 5;  Ad = "Internet Download Manager"; Id = "Tonec.InternetDownloadManager" }
    @{ No = 6;  Ad = "Mozilla Firefox";           Id = "Mozilla.Firefox" }
    @{ No = 7;  Ad = "VLC Media Player";          Id = "VideoLAN.VLC" }
    @{ No = 8;  Ad = "Notepad++";                 Id = "Notepad++.Notepad++" }
    @{ No = 9;  Ad = "Visual Studio Code";        Id = "Microsoft.VisualStudioCode" }
    @{ No = 10; Ad = "UniGetUI";                  Id = "MartiCliment.UniGetUI" }
    @{ No = 11; Ad = "PowerToys";                 Id = "Microsoft.PowerToys" }
    @{ No = 12; Ad = "PowerShell 7";              Id = "Microsoft.PowerShell" }
    @{ No = 13; Ad = "Oracle Java Runtime";       Id = "Oracle.JavaRuntimeEnvironment" }
    @{ No = 14; Ad = "Microsoft PC Manager";      Id = "9PM860492SZD"; Kaynak = "msstore" }
    @{ No = 15; Ad = "Windows Terminal";          Id = "Microsoft.WindowsTerminal" }
    @{ No = 16; Ad = "Alpemix (Uzak BaÃ„Å¸lantÃ„Â±)";   Id = "ALPEMIX_OZEL" }
)

# ===================== UYGULAMA KURULUM =====================

function Install-App {
    param([string]$Ad, [string]$Id, [string]$Kaynak = "winget")

    if ($Id -eq "ALPEMIX_OZEL") {
        Install-Alpemix
        return
    }

    # winget yoksa erken ÃƒÂ§Ã„Â±k
    if (-not $WingetVar) {
        Write-Result $false "$Ad kurulamadÃ„Â±: winget bulunamadÃ„Â±."
        return
    }

    Write-Host "  $Ad kuruluyor..." -ForegroundColor Yellow

    # Store uygulamalarÃ„Â± iÃƒÂ§in msstore kaynaÃ„Å¸Ã„Â±, diÃ„Å¸erleri iÃƒÂ§in varsayÃ„Â±lan winget kaynaÃ„Å¸Ã„Â±
    if ($Kaynak -eq "msstore") {
        $argumanlar = "install --id $Id --source msstore --accept-package-agreements --accept-source-agreements"
    } else {
        $argumanlar = "install --id $Id --silent --accept-package-agreements --accept-source-agreements"
    }

    $sonuc = Start-Process winget -ArgumentList $argumanlar -Wait -PassThru -NoNewWindow
    switch ($sonuc.ExitCode) {
        0           { Write-Result $true "$Ad baÃ…Å¸arÃ„Â±yla kuruldu." }
        -1978335189 { Write-Result $true "$Ad zaten gÃƒÂ¼ncel / yÃƒÂ¼klÃƒÂ¼." }
        default     { Write-Result $false "$Ad kurulamadÃ„Â± (Kod: $($sonuc.ExitCode))." }
    }
}

# ===================== ALPEMIX Ãƒâ€“ZEL Ã„Â°NDÃ„Â°RME (Ã„Â°MZA KONTROLLÃƒÅ“) =====================
function Install-Alpemix {
    Write-Host "  Alpemix indiriliyor..." -ForegroundColor Yellow
    try {
        $masaustu = [Environment]::GetFolderPath("Desktop")
        $hedef = Join-Path $masaustu "Alpemix.exe"
        $url = "https://www.alpemix.com/site/Alpemix.exe"

        try {
            [Net.ServicePointManager]::SecurityProtocol = `
                [Net.SecurityProtocolType]::Tls12 -bor [Net.SecurityProtocolType]::Tls13
        } catch {
            [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
        }

        Invoke-WebRequest -Uri $url -OutFile $hedef -UseBasicParsing -ErrorAction Stop

        if (-not (Test-Path $hedef)) {
            Write-Result $false "Alpemix indirilemedi."
            return
        }
        $boyutKB = [math]::Round((Get-Item $hedef).Length / 1KB, 1)
        if ($boyutKB -lt 50) {
            Write-Result $false "Ã„Â°ndirilen dosya bozuk gÃƒÂ¶rÃƒÂ¼nÃƒÂ¼yor ($boyutKB KB). Ã„Â°ptal edildi."
            Remove-Item $hedef -Force -ErrorAction SilentlyContinue
            return
        }
        Write-Result $true "Alpemix indirildi: $hedef ($boyutKB KB)"

        $imza = Get-AuthenticodeSignature $hedef
        $imzaGuvenli = $false
        switch ($imza.Status) {
            "Valid" {
                $imzaci = $imza.SignerCertificate.Subject
                Write-Result $true "Dijital imza GEÃƒâ€¡ERLÃ„Â°."
                Write-Host ("       Ã„Â°mzalayan: " + $imzaci) -ForegroundColor DarkGray
                $imzaGuvenli = $true
            }
            "NotSigned" {
                Write-Result $false "UYARI: Dosya dijital olarak Ã„Â°MZALANMAMIÃ…Â."
            }
            default {
                Write-Result $false ("UYARI: Ã„Â°mza durumu gÃƒÂ¼vensiz: " + $imza.Status)
            }
        }

        if (-not $imzaGuvenli) {
            Write-Host ""
            Write-Host "  Bu dosyanÃ„Â±n imzasÃ„Â± doÃ„Å¸rulanamadÃ„Â±. YalnÃ„Â±zca kaynaÃ„Å¸a" -ForegroundColor Yellow
            Write-Host "  gÃƒÂ¼veniyorsanÃ„Â±z ÃƒÂ§alÃ„Â±Ã…Å¸tÃ„Â±rÃ„Â±n." -ForegroundColor Yellow
        }
        $ac = Read-Host "  Alpemix Ã…Å¸imdi ÃƒÂ§alÃ„Â±Ã…Å¸tÃ„Â±rÃ„Â±lsÃ„Â±n mÃ„Â±? (E/H)"
        if ($ac -eq "E" -or $ac -eq "e") {
            Start-Process $hedef
            Write-Result $true "Alpemix baÃ…Å¸latÃ„Â±ldÃ„Â±."
        } else {
            Write-Result $true "Ãƒâ€¡alÃ„Â±Ã…Å¸tÃ„Â±rma iptal edildi. Dosya masaÃƒÂ¼stÃƒÂ¼nde duruyor."
        }
    } catch {
        Write-Result $false "Alpemix indirilemedi: $($_.Exception.Message)"
    }
}

# ===================== TÃƒÅ“M UYGULAMALARI GÃƒÅ“NCELLE =====================
function Update-AllApps {
    Show-Header "TÃƒÅ“M UYGULAMALARI GÃƒÅ“NCELLE"

    # Winget yoksa yardÃ„Â±m ekranÃ„Â±nÃ„Â± gÃƒÂ¶ster (Kod 2'den)
    if (-not $WingetVar) {
        Show-WingetHelp
        return
    }

    Write-Host "  Sistemde yÃƒÂ¼klÃƒÂ¼ tÃƒÂ¼m programlar gÃƒÂ¼ncelleniyor..." -ForegroundColor "Yellow"
    Write-Host "  (winget upgrade --all)" -ForegroundColor $Tema.Soluk
    Write-Host ""

    if (-not (Confirm-Islem "TÃƒÂ¼m uygulamalar gÃƒÂ¼ncellensin mi?")) {
        Write-Result $false "Ã„Â°Ã…Å¸lem iptal edildi."
        Read-Host "  Devam etmek iÃƒÂ§in Enter'a basÃ„Â±n"
        return
    }

    Write-Host ""
    Write-Host "  GÃƒÂ¼ncelleme baÃ…Å¸latÃ„Â±lÃ„Â±yor, lÃƒÂ¼tfen bekleyin..." -ForegroundColor $Tema.Vurgu
    Write-Host "  (Bu iÃ…Å¸lem birkaÃƒÂ§ dakika sÃƒÂ¼rebilir.)" -ForegroundColor $Tema.Soluk
    Write-Host ""

    try {
        # KRÃ„Â°TÃ„Â°K: --disable-interactivity + --silent (Kod 1'den) Ã¢â€ â€™ takÃ„Â±lma/ÃƒÂ§ift onay engellenir
        winget upgrade --all `
            --include-unknown `
            --disable-interactivity `
            --accept-package-agreements `
            --accept-source-agreements `
            --silent
        $kod = $LASTEXITCODE
    } catch {
        $kod = -1
    }

    # ===== Ãƒâ€“ZET KUTUSU (Kod 2'den) =====
    Write-Host ""
    Show-Top
    Show-Line "  GÃƒÅ“NCELLEME Ãƒâ€“ZETÃ„Â°" $Tema.Baslik
    Show-Divider
    if ($kod -eq 0 -or $null -eq $kod) {
        Show-Line "  Ã¢Å“â€œ GÃƒÂ¼ncelleme iÃ…Å¸lemi tamamlandÃ„Â±." $Tema.Basari
    } else {
        Show-Line "  Ã¢Å¡Â  BazÃ„Â± paketler gÃƒÂ¼ncellenemedi (ÃƒÂ§Ã„Â±kÃ„Â±Ã…Å¸ kodu: $kod)." $Tema.Hata
    }
    Show-Line "  Not: GÃƒÂ¼ncellenecek paket yoksa 'her Ã…Å¸ey gÃƒÂ¼ncel' demektir." $Tema.Soluk
    Show-Bottom

    Write-Host ""
    Read-Host "  Devam etmek iÃƒÂ§in Enter'a basÃ„Â±n"
}
# ===================== SÃ„Â°STEM FONKSÃ„Â°YONLARI =====================

function New-AdminFolders {
    Show-Header "YÃƒâ€“NETÃ„Â°M KLASÃƒâ€“RLERÃ„Â° OLUÃ…ÂTUR"
    Write-Host ""
    $onay = Read-Host "  MasaÃƒÂ¼stÃƒÂ¼nde Admin ve GodMode klasÃƒÂ¶rleri oluÃ…Å¸turulsun mu? (E/H)"
    if ($onay -ne "E" -and $onay -ne "e") {
        Write-Result $false "Ã„Â°Ã…Å¸lem iptal edildi."; Write-Host ""; Read-Host "  Devam etmek iÃƒÂ§in Enter'a basÃ„Â±n"; return
    }
    $masaustu = [Environment]::GetFolderPath("Desktop")
    try {
        $adminYol   = Join-Path $masaustu "YÃƒÂ¶netim AraÃƒÂ§larÃ„Â±.{D20EA4E1-3957-11d2-A40B-0C5020524153}"
        $godmodeYol = Join-Path $masaustu "GodMode.{ED7BA470-8E54-465E-825C-99712043E01C}"
        if (-not (Test-Path $adminYol))   { New-Item -Path $adminYol -ItemType Directory -Force | Out-Null }
        if (-not (Test-Path $godmodeYol)) { New-Item -Path $godmodeYol -ItemType Directory -Force | Out-Null }
        Write-Result $true "YÃƒÂ¶netim ve GodMode klasÃƒÂ¶rleri masaÃƒÂ¼stÃƒÂ¼nde oluÃ…Å¸turuldu."
    } catch {
        Write-Result $false "KlasÃƒÂ¶r oluÃ…Å¸turulamadÃ„Â±: $($_.Exception.Message)"
    }
    Write-Host ""
    Read-Host "  Devam etmek iÃƒÂ§in Enter'a basÃ„Â±n"
}

function Show-SystemInfo {
    Show-Header "SÃ„Â°STEM BÃ„Â°LGÃ„Â°LERÃ„Â°"
    try {
        $os  = Get-CimInstance Win32_OperatingSystem
        $cs  = Get-CimInstance Win32_ComputerSystem
        $cpu = Get-CimInstance Win32_Processor | Select-Object -First 1
        
        # DOÃ„ÂRU RAM HESABI (Hem fiziksel hem sanal makine uyumlu)
        $ram = [math]::Round($os.TotalVisibleMemorySize / 1024 / 1024)

        Write-Host ("  Bilgisayar : " + $cs.Name)          -ForegroundColor $Tema.Baslik
        Write-Host ("  Ã„Â°Ã…Å¸letim S. : " + $os.Caption)       -ForegroundColor $Tema.Baslik
        Write-Host ("  SÃƒÂ¼rÃƒÂ¼m      : " + $os.Version)        -ForegroundColor $Tema.Metin
        Write-Host ("  Ã„Â°Ã…Å¸lemci    : " + $cpu.Name.Trim())   -ForegroundColor $Tema.Metin
        Write-Host ("  RAM        : " + $ram + " GB")        -ForegroundColor $Tema.Metin
        Write-Host ("  ÃƒÅ“retici    : " + $cs.Manufacturer)   -ForegroundColor $Tema.Metin
    } catch {
        Write-Host ("  Bilgi alÃ„Â±namadÃ„Â±: " + $_.Exception.Message) -ForegroundColor $Tema.Hata
    }
    Write-Host ""
    Read-Host "  Devam etmek iÃƒÂ§in Enter'a basÃ„Â±n"
}
function Show-DiskSummary {
    Show-Header "DÃ„Â°SK Ãƒâ€“ZETÃ„Â°"
    try {
        Get-CimInstance Win32_LogicalDisk -Filter "DriveType=3" | ForEach-Object {
            $toplam = [math]::Round($_.Size / 1GB, 1)
            $bos    = [math]::Round($_.FreeSpace / 1GB, 1)
            $dolu   = $toplam - $bos
            $yuzde  = if ($toplam -gt 0) { [math]::Round(($dolu / $toplam) * 100) } else { 0 }
            Write-Host ("  SÃƒÂ¼rÃƒÂ¼cÃƒÂ¼ " + $_.DeviceID + "  Toplam: $toplam GB  BoÃ…Å¸: $bos GB  (%$yuzde dolu)") -ForegroundColor $Tema.Baslik
        }
    } catch {
        Write-Host ("  Disk bilgisi alÃ„Â±namadÃ„Â±.") -ForegroundColor $Tema.Hata
    }
    Write-Host ""
    Read-Host "  Devam etmek iÃƒÂ§in Enter'a basÃ„Â±n"
}

function Show-DiskHealth {
    Show-Header "DÃ„Â°SK SAÃ„ÂLIÃ„ÂI (SMART)"
    try {
        Get-PhysicalDisk | ForEach-Object {
            $durum = $_.HealthStatus
            $renk = if ($durum -eq "Healthy") { $Tema.Basari } else { $Tema.Hata }
            Write-Host ("  " + $_.FriendlyName + "  Durum: " + $durum) -ForegroundColor $renk
        }
    } catch {
        Write-Host ("  Disk saÃ„Å¸lÃ„Â±k bilgisi alÃ„Â±namadÃ„Â±.") -ForegroundColor $Tema.Hata
    }
    Write-Host ""
    Read-Host "  Devam etmek iÃƒÂ§in Enter'a basÃ„Â±n"
}
function Show-Startup {
    Show-Header "BAÃ…ÂLANGIÃƒâ€¡ PROGRAMLARI"

    # --- KayÃ„Â±tlÃ„Â± baÃ…Å¸langÃ„Â±ÃƒÂ§ programlarÃ„Â±nÃ„Â± listele + say ---
    $sayac = 0
    try {
        Get-CimInstance Win32_StartupCommand | ForEach-Object {
            $sayac++
            Write-Host ("  " + $_.Name + "  ->  " + $_.Command) -ForegroundColor $Tema.Metin
        }
        if ($sayac -eq 0) {
            Write-Host "  KayÃ„Â±tlÃ„Â± baÃ…Å¸langÃ„Â±ÃƒÂ§ programÃ„Â± bulunamadÃ„Â±." -ForegroundColor $Tema.Soluk
        } else {
            Write-Host ("  " + ("-" * 50)) -ForegroundColor $Tema.Cerceve
            Write-Host ("  Toplam $sayac baÃ…Å¸langÃ„Â±ÃƒÂ§ programÃ„Â± bulundu.") -ForegroundColor $Tema.Vurgu
        }
    } catch {
        Write-Host "  BaÃ…Å¸langÃ„Â±ÃƒÂ§ programlarÃ„Â± alÃ„Â±namadÃ„Â±." -ForegroundColor $Tema.Hata
    }

    Write-Host ""

    # --- E/H sorusu: BaÃ…Å¸langÃ„Â±ÃƒÂ§ ayar ekranÃ„Â±nÃ„Â± aÃƒÂ§mak ister mi? ---
    Write-Host "  Windows BaÃ…Å¸langÃ„Â±ÃƒÂ§ ayarlarÃ„Â±nÃ„Â± aÃƒÂ§mak ister misiniz? " -NoNewline -ForegroundColor $Tema.Metin
    Write-Host "(E/H)" -ForegroundColor $Tema.Vurgu
    $cevap = Read-Host "  SeÃƒÂ§iminiz"

    if ($cevap -match '^[EeYy]') {
        Write-Host ""
        Write-Host "  Windows BaÃ…Å¸langÃ„Â±ÃƒÂ§ ayarlarÃ„Â± aÃƒÂ§Ã„Â±lÃ„Â±yor..." -ForegroundColor $Tema.Metin
        try {
            Start-Process "ms-settings:startupapps" -ErrorAction Stop
            Write-Result $true "Ayarlar > BaÃ…Å¸langÃ„Â±ÃƒÂ§ sayfasÃ„Â± aÃƒÂ§Ã„Â±ldÃ„Â±."
        } catch {
            try {
                Start-Process "taskmgr.exe" -ArgumentList "/0 /startup" -ErrorAction Stop
                Write-Result $true "GÃƒÂ¶rev YÃƒÂ¶neticisi (BaÃ…Å¸langÃ„Â±ÃƒÂ§ sekmesi) aÃƒÂ§Ã„Â±ldÃ„Â±."
            } catch {
                Write-Result $false "BaÃ…Å¸langÃ„Â±ÃƒÂ§ ayarlarÃ„Â± aÃƒÂ§Ã„Â±lamadÃ„Â±: $($_.Exception.Message)"
            }
        }
    } else {
        Write-Host ""
        Write-Result $true "BaÃ…Å¸langÃ„Â±ÃƒÂ§ ayarlarÃ„Â± aÃƒÂ§Ã„Â±lmadÃ„Â±. Ana menÃƒÂ¼ye dÃƒÂ¶nÃƒÂ¼lÃƒÂ¼yor."
    }

    Read-Host "`n  Devam etmek iÃƒÂ§in Enter'a basÃ„Â±n"
}

function Start-WindowsUpdate {
    Show-Header "WINDOWS GÃƒÅ“NCELLEMELERÃ„Â°"
    Write-Host ""
    $onay = Read-Host "  Windows gÃƒÂ¼ncellemeleri aranÃ„Â±p kurulsun mu? (E/H)"
    if ($onay -ne "E" -and $onay -ne "e") {
        Write-Result $false "Ã„Â°Ã…Å¸lem iptal edildi."; Write-Host ""; Read-Host "  Devam etmek iÃƒÂ§in Enter'a basÃ„Â±n"; return
    }
    try {
        if (-not (Get-Module -ListAvailable -Name PSWindowsUpdate)) {
            Write-Progress -Activity "Windows Update" -Status "PSWindowsUpdate modÃƒÂ¼lÃƒÂ¼ kuruluyor..." -PercentComplete 10
            Write-Host "  [1/3] PSWindowsUpdate modÃƒÂ¼lÃƒÂ¼ kuruluyor..." -ForegroundColor Yellow
            Install-PackageProvider -Name NuGet -Force -ErrorAction SilentlyContinue | Out-Null
            Install-Module PSWindowsUpdate -Force -Scope CurrentUser -Confirm:$false -ErrorAction SilentlyContinue
        } else {
            Write-Host "  [1/3] PSWindowsUpdate modÃƒÂ¼lÃƒÂ¼ hazÃ„Â±r." -ForegroundColor DarkGray
        }

        Write-Progress -Activity "Windows Update" -Status "ModÃƒÂ¼l yÃƒÂ¼kleniyor..." -PercentComplete 40
        Import-Module PSWindowsUpdate -ErrorAction SilentlyContinue

        Write-Progress -Activity "Windows Update" -Status "GÃƒÂ¼ncellemeler aranÃ„Â±yor ve kuruluyor..." -PercentComplete 70
        Write-Host "  [2/3] GÃƒÂ¼ncellemeler aranÃ„Â±yor..." -ForegroundColor Yellow
        Write-Host "  [3/3] Bulunanlar kuruluyor (bu iÃ…Å¸lem uzun sÃƒÂ¼rebilir)..." -ForegroundColor Yellow
        Write-Host ""

        # -Verbose ile her gÃƒÂ¼ncellemenin durumu ekrana yansÃ„Â±r
        Get-WindowsUpdate -AcceptAll -Install -IgnoreReboot -Verbose

        Write-Progress -Activity "Windows Update" -Completed
        Write-Host ""
        Write-Result $true "Windows gÃƒÂ¼ncelleme iÃ…Å¸lemi tamamlandÃ„Â±."
    } catch {
        Write-Progress -Activity "Windows Update" -Completed
        Write-Result $false "GÃƒÂ¼ncelleme yapÃ„Â±lamadÃ„Â±: $($_.Exception.Message)"
    }
    Write-Host ""
    Read-Host "  Devam etmek iÃƒÂ§in Enter'a basÃ„Â±n"
}

function Reset-Network {
    Show-Header "AÃ„Â SIFIRLAMA"
    Write-Host ""
if (-not (Confirm-Islem "AÃ„Å¸ ayarlarÃ„Â± sÃ„Â±fÃ„Â±rlanacak (DNS, Winsock, IP). Emin misiniz?")) {
    Write-Result $false "Ã„Â°Ã…Å¸lem iptal edildi."
    Write-Host ""; Read-Host "  Devam etmek iÃƒÂ§in Enter'a basÃ„Â±n"; return
}

    try {
        ipconfig /flushdns | Out-Null
        netsh winsock reset | Out-Null
        netsh int ip reset | Out-Null
        Write-Result $true "AÃ„Å¸ ayarlarÃ„Â± sÃ„Â±fÃ„Â±rlandÃ„Â±. BilgisayarÃ„Â± yeniden baÃ…Å¸latÃ„Â±n."
    } catch {
        Write-Result $false "AÃ„Å¸ sÃ„Â±fÃ„Â±rlanamadÃ„Â±: $($_.Exception.Message)"
    }
    Write-Host ""
    Read-Host "  Devam etmek iÃƒÂ§in Enter'a basÃ„Â±n"
}

function New-RestorePoint {
    Show-Header "SÃ„Â°STEM GERÃ„Â° YÃƒÅ“KLEME NOKTASI"
    Write-Host ""
    $onay = Read-Host "  Sistem geri yÃƒÂ¼kleme noktasÃ„Â± oluÃ…Å¸turulsun mu? (E/H)"
    if ($onay -ne "E" -and $onay -ne "e") {
        Write-Result $false "Ã„Â°Ã…Å¸lem iptal edildi."; Write-Host ""; Read-Host "  Devam etmek iÃƒÂ§in Enter'a basÃ„Â±n"; return
    }

try {
        Enable-ComputerRestore -Drive "C:\" -ErrorAction SilentlyContinue
        Checkpoint-Computer -Description "Bilgisayar Araci - $(Get-Date -Format 'yyyy-MM-dd HH:mm')" -RestorePointType "MODIFY_SETTINGS" -ErrorAction Stop
        Write-Result $true "Geri yÃƒÂ¼kleme noktasÃ„Â± oluÃ…Å¸turuldu."
    } catch {
        Write-Result $false "Geri yÃƒÂ¼kleme noktasÃ„Â± oluÃ…Å¸turulamadÃ„Â±: $($_.Exception.Message)"
    }

    Write-Host ""
    Read-Host "  Devam etmek iÃƒÂ§in Enter'a basÃ„Â±n"
}

function Clear-PrintQueue {
    Show-Header "YAZICI KUYRUÃ„ÂUNU TEMÃ„Â°ZLE"
    Write-Host ""
    $onay = Read-Host "  YazÃ„Â±cÃ„Â± kuyruÃ„Å¸u temizlenecek. OnaylÃ„Â±yor musunuz? (E/H)"
    if ($onay -ne "E" -and $onay -ne "e") {
        Write-Result $false "Ã„Â°Ã…Å¸lem iptal edildi."; Write-Host ""; Read-Host "  Devam etmek iÃƒÂ§in Enter'a basÃ„Â±n"; return
    }
    try {
        Stop-Service -Name Spooler -Force -ErrorAction SilentlyContinue
        Remove-Item "$env:SystemRoot\System32\spool\PRINTERS\*" -Force -ErrorAction SilentlyContinue
        Start-Service -Name Spooler -ErrorAction SilentlyContinue
        Write-Result $true "YazÃ„Â±cÃ„Â± kuyruÃ„Å¸u temizlendi."
    } catch {
        Write-Result $false "YazÃ„Â±cÃ„Â± kuyruÃ„Å¸u temizlenemedi: $($_.Exception.Message)"
    }
    Write-Host ""
    Read-Host "  Devam etmek iÃƒÂ§in Enter'a basÃ„Â±n"
}

function Show-HealthSummary {
    Show-Header "SÃ„Â°STEM SAÃ„ÂLIK Ãƒâ€“ZETÃ„Â°"
    try {
        $os  = Get-CimInstance Win32_OperatingSystem
        $cs  = Get-CimInstance Win32_ComputerSystem
        
        # DOÃ„ÂRU RAM HESABI
        $ram = [math]::Round($os.TotalVisibleMemorySize / 1024 / 1024)
        $bosRam = [math]::Round($os.FreePhysicalMemory / 1024 / 1024, 1)
        
        $cDisk = Get-CimInstance Win32_LogicalDisk -Filter "DeviceID='C:'"
        $cBos = [math]::Round($cDisk.FreeSpace / 1GB, 1)
        $cTop = [math]::Round($cDisk.Size / 1GB, 1)
        $uptime = (Get-Date) - $os.LastBootUpTime

        Write-Host ("  RAM        : " + $ram + " GB  (BoÃ…Å¸: " + $bosRam + " GB)") -ForegroundColor $Tema.Baslik
        Write-Host ("  C: Disk    : " + $cTop + " GB  (BoÃ…Å¸: " + $cBos + " GB)") -ForegroundColor $Tema.Baslik
        Write-Host ("  Ãƒâ€¡alÃ„Â±Ã…Å¸ma S. : " + $uptime.Days + " gÃƒÂ¼n " + $uptime.Hours + " saat") -ForegroundColor $Tema.Metin

        $cYuzde = if ($cTop -gt 0) { [math]::Round((($cTop - $cBos) / $cTop) * 100) } else { 0 }
        Write-Host ("  " + ("-" * 50)) -ForegroundColor $Tema.Cerceve
        if ($cYuzde -gt 90) { Write-Host "  Ã¢Å¡Â  C: sÃƒÂ¼rÃƒÂ¼cÃƒÂ¼sÃƒÂ¼ neredeyse dolu!" -ForegroundColor $Tema.Hata }
        elseif ($cYuzde -gt 75) { Write-Host "  Ã¢Å¡Â  C: sÃƒÂ¼rÃƒÂ¼cÃƒÂ¼sÃƒÂ¼nde yer azalÃ„Â±yor." -ForegroundColor Yellow }
        else { Write-Host "  Ã¢Å“â€œ Disk durumu iyi." -ForegroundColor $Tema.Basari }

        if ($bosRam -lt 1) { Write-Host "  Ã¢Å¡Â  BoÃ…Å¸ RAM dÃƒÂ¼Ã…Å¸ÃƒÂ¼k!" -ForegroundColor $Tema.Hata }
        else { Write-Host "  Ã¢Å“â€œ RAM durumu iyi." -ForegroundColor $Tema.Basari }
    } catch {
        Write-Host ("  SaÃ„Å¸lÃ„Â±k ÃƒÂ¶zeti alÃ„Â±namadÃ„Â±: " + $_.Exception.Message) -ForegroundColor $Tema.Hata
    }
    Write-Host ""
    Read-Host "  Devam etmek iÃƒÂ§in Enter'a basÃ„Â±n"
}

# ===================== GÃƒÅ“VENLÃ„Â°K: TEHLÃ„Â°KELÃ„Â° YOL KONTROLÃƒÅ“ (SON HAL v2) =====================
$Global:YasakliYollar = @(
    "$env:SystemRoot",
    "$env:SystemRoot\System32",
    "$env:ProgramFiles",
    "${env:ProgramFiles(x86)}",
    "$env:SystemDrive\",
    "$env:USERPROFILE",
    "$env:SystemDrive\Users",
    "$env:SystemDrive\Windows"
) | Where-Object { $_ } | ForEach-Object { $_.TrimEnd('\').ToLower() }

function Test-GuvenliYol {
    param([string]$Yol)

    if ([string]::IsNullOrWhiteSpace($Yol)) { return $false }

    try {
        $tam = [System.IO.Path]::GetFullPath($Yol).TrimEnd('\').ToLower()
    } catch {
        return $false
    }

    if ($tam.Length -lt 8) { return $false }
    if ($tam -match '^[a-z]:$') { return $false }

    $izinliDesenler = @(
        '\\temp$',        
        '\\prefetch$',    
        '\\explorer$',    
        '\\inetcache',    
        '\\cache$',       
        '\\recent$'       
    )
    foreach ($desen in $izinliDesenler) {
        if ($tam -imatch $desen) { return $true }
    }

    if ($Global:YasakliYollar -contains $tam) { return $false }
    foreach ($yasak in $Global:YasakliYollar) {
        if ($yasak -eq $tam -or $yasak.StartsWith($tam + '\')) { return $false }
    }

    return $false
}
# ===================== TEMÃ„Â°ZLÃ„Â°K FONKSÃ„Â°YONLARI =====================
function Clean-Temp {
    Show-Header "GEÃƒâ€¡Ã„Â°CÃ„Â° DOSYALARI TEMÃ„Â°ZLE"

    $hedefler = @(
        @{ Ad = "KullanÃ„Â±cÃ„Â± TEMP";        Yol = $env:TEMP }
        @{ Ad = "Windows TEMP";          Yol = "$env:SystemRoot\Temp" }
        @{ Ad = "Yerel AppData TEMP";    Yol = "$env:LOCALAPPDATA\Temp" }
        @{ Ad = "Prefetch";              Yol = "$env:SystemRoot\Prefetch" }
        @{ Ad = "Thumbnail Ãƒâ€“nbellek";    Yol = "$env:LOCALAPPDATA\Microsoft\Windows\Explorer" }
        @{ Ad = "Son KullanÃ„Â±lanlar";     Yol = "$env:APPDATA\Microsoft\Windows\Recent" }
    )

    if (-not (Confirm-Islem "GeÃƒÂ§ici dosyalar temizlensin mi?")) {
        Write-Result $false "Ã„Â°Ã…Å¸lem iptal edildi."
        Read-Host "  Devam etmek iÃƒÂ§in Enter'a basÃ„Â±n"
        return
    }

    Write-Host ""
    $toplamKazanc = 0.0
    $toplamSilinen = 0
    $toplamHata    = 0

    foreach ($k in $hedefler) {
        if ([string]::IsNullOrWhiteSpace($k.Yol) -or -not (Test-Path $k.Yol)) {
            Write-Host ("  Ã¢â€“Â¸ " + $k.Ad + " Ã¢â‚¬â€ bulunamadÃ„Â±, atlandÃ„Â±.") -ForegroundColor $Tema.Soluk
            continue
        }

        if (-not (Test-GuvenliYol $k.Yol)) {
            Write-Host ("  Ã¢Å¡Â  " + $k.Ad + " Ã¢â‚¬â€ GÃƒÅ“VENLÃ„Â°K nedeniyle atlandÃ„Â±.") -ForegroundColor Yellow
            continue
        }

        $hedefKazanc  = 0.0
        $hedefSilinen = 0
        $hedefHata    = 0

        $dosyalar = Get-ChildItem -Path $k.Yol -Recurse -Force -File -ErrorAction SilentlyContinue
        foreach ($d in $dosyalar) {
            try {
                $boyutMB = $d.Length / 1MB
                Remove-Item -LiteralPath $d.FullName -Force -ErrorAction Stop
                $hedefKazanc  += $boyutMB
                $hedefSilinen++
            } catch {
                $hedefHata++
            }
        }

        Get-ChildItem -Path $k.Yol -Recurse -Force -Directory -ErrorAction SilentlyContinue |
            Sort-Object FullName -Descending |
            ForEach-Object {
                try { Remove-Item -LiteralPath $_.FullName -Force -Recurse -ErrorAction Stop } catch {}
            }

        $hedefKazancYuvarli = [math]::Round($hedefKazanc, 2)
        Write-Host ("  Ã¢Å“â€œ " + $k.Ad.PadRight(22) + " temizlendi Ã¢â‚¬â€ $hedefSilinen dosya, $hedefKazancYuvarli MB") -ForegroundColor $Tema.Basari

        $toplamKazanc  += $hedefKazanc
        $toplamSilinen += $hedefSilinen
        $toplamHata    += $hedefHata
    }

    $kazancYuvarli = [math]::Round($toplamKazanc, 2)

    # ===== Ãƒâ€“ZET KUTUSU =====
    Write-Host ""
    Show-Top
    Show-Line "  TEMÃ„Â°ZLÃ„Â°K Ãƒâ€“ZETÃ„Â°" $Tema.Baslik
    Show-Divider
    Show-Line ("  Silinen dosya    : " + $toplamSilinen) $Tema.Metin
    Show-Line ("  KazanÃ„Â±lan alan   : " + $kazancYuvarli + " MB") $Tema.Basari
    if ($toplamHata -gt 0) {
        Show-Line ("  Atlanan (kilitli): " + $toplamHata + " dosya (normal)") $Tema.Soluk
    }
    Show-Bottom

    Write-Host ""
    Write-Host "  Not: Prefetch silindiÃ„Å¸i iÃƒÂ§in ilk aÃƒÂ§Ã„Â±lÃ„Â±Ã…Å¸lar biraz yavaÃ…Å¸" -ForegroundColor $Tema.Soluk
    Write-Host "  olabilir, sistem birkaÃƒÂ§ aÃƒÂ§Ã„Â±lÃ„Â±Ã…Å¸ta yeniden oluÃ…Å¸turur." -ForegroundColor $Tema.Soluk

    Write-Host ""
    Read-Host "  Devam etmek iÃƒÂ§in Enter'a basÃ„Â±n"
}
function Clean-Logs {
    Show-Header "OLAY GÃƒÅ“NLÃƒÅ“KLERÃ„Â°NÃ„Â° TEMÃ„Â°ZLE"

    Write-Host "  Windows olay gÃƒÂ¼nlÃƒÂ¼kleri temizleniyor..." -ForegroundColor "Yellow"
    Write-Host "  (Bu iÃ…Å¸lem birkaÃƒÂ§ dakika sÃƒÂ¼rebilir, lÃƒÂ¼tfen bekleyin)" -ForegroundColor $Tema.Soluk
    Write-Host ""

    if (-not (Confirm-Islem "TÃƒÂ¼m olay gÃƒÂ¼nlÃƒÂ¼kleri temizlensin mi?")) {
        Write-Result $false "Ã„Â°Ã…Å¸lem iptal edildi."
        Read-Host "  Devam etmek iÃƒÂ§in Enter'a basÃ„Â±n"
        return
    }

    Write-Host ""

    try {
        $loglar = @(wevtutil el 2>$null)
        $toplam = $loglar.Count

        if ($toplam -eq 0) {
            Write-Result $false "Temizlenecek olay gÃƒÂ¼nlÃƒÂ¼Ã„Å¸ÃƒÂ¼ bulunamadÃ„Â±."
            Write-Host ""
            Read-Host "  Devam etmek iÃƒÂ§in Enter'a basÃ„Â±n"
            return
        }

        $sayac    = 0
        $basarili = 0
        $zamanAsimi = 0

        foreach ($log in $loglar) {
            $sayac++

            $yuzde = [math]::Round(($sayac / $toplam) * 100)
            $dolu  = [math]::Round($yuzde / 100 * 30)
            $cubuk = ("Ã¢â€“Ë†" * $dolu) + ("Ã¢â€“â€˜" * (30 - $dolu))
            Write-Host ("`r  [$cubuk]  %$yuzde  ($sayac/$toplam)   ") -ForegroundColor Yellow -NoNewline

            try {
                $psi = New-Object System.Diagnostics.ProcessStartInfo
                $psi.FileName               = "wevtutil.exe"
                $psi.Arguments              = "cl `"$log`""
                $psi.UseShellExecute        = $false
                $psi.RedirectStandardOutput = $true
                $psi.RedirectStandardError  = $true
                $psi.CreateNoWindow         = $true
                $proc = New-Object System.Diagnostics.Process
                $proc.StartInfo = $psi
                $proc.Start() | Out-Null
                if ($proc.WaitForExit(5000)) {
                    if ($proc.ExitCode -eq 0) { $basarili++ }
                } else {
                    try { $proc.Kill() } catch {}
                    $zamanAsimi++
                    Yaz-Log "Olay gunlugu temizleme zaman asimina ugradi: $log" 'UYARI'
                }
            } catch {
                Yaz-Log "Olay gunlugu temizlenemedi: $log -> $($_.Exception.Message)" 'UYARI'
            }
        }
        Write-Host ("`r  [" + ("Ã¢â€“Ë†" * 30) + "]  %100  tamamlandÃ„Â±            ") -ForegroundColor Green
        Write-Host ""

        Write-Result $true "$basarili / $toplam olay gÃƒÂ¼nlÃƒÂ¼Ã„Å¸ÃƒÂ¼ temizlendi."
        if ($zamanAsimi -gt 0) {
            Write-Host "  Not: $zamanAsimi gÃƒÂ¼nlÃƒÂ¼k zaman aÃ…Å¸Ã„Â±mÃ„Â±na uÃ„Å¸radÃ„Â±Ã„Å¸Ã„Â± iÃƒÂ§in atlandÃ„Â±." -ForegroundColor $Tema.Soluk
        }
        if ($basarili -lt $toplam) {
            Write-Host "  Not: BazÃ„Â± korumalÃ„Â± gÃƒÂ¼nlÃƒÂ¼kler temizlenemez (normaldir)." -ForegroundColor $Tema.Soluk
        }
    } catch {
        Write-Result $false ("GÃƒÂ¼nlÃƒÂ¼kler temizlenirken hata: " + $_.Exception.Message)
    }

    Write-Host ""
    Read-Host "  Devam etmek iÃƒÂ§in Enter'a basÃ„Â±n"
}
function Clean-WinUpdate {
    Show-Header "WINDOWS UPDATE Ãƒâ€“NBELLEÃ„ÂÃ„Â°NÃ„Â° TEMÃ„Â°ZLE"
    try {
        Stop-Service -Name wuauserv -Force -ErrorAction SilentlyContinue
        Remove-Item "$env:SystemRoot\SoftwareDistribution\Download\*" -Recurse -Force -ErrorAction SilentlyContinue
        Start-Service -Name wuauserv -ErrorAction SilentlyContinue
        Write-Result $true "Windows Update ÃƒÂ¶nbelleÃ„Å¸i temizlendi."
    } catch {
        Write-Result $false "Ãƒâ€“nbellek temizlenemedi: $($_.Exception.Message)"
    }
    Write-Host ""
    Read-Host "  Devam etmek iÃƒÂ§in Enter'a basÃ„Â±n"
}

function Clean-RecycleBin {
    Show-Header "GERÃ„Â° DÃƒâ€“NÃƒÅ“Ã…ÂÃƒÅ“M KUTUSU TEMÃ„Â°ZLE"
    Write-Host ""

    try {
        Clear-RecycleBin -Force -ErrorAction Stop
        Write-Host "  Ã¢Å“â€œ  Geri dÃƒÂ¶nÃƒÂ¼Ã…Å¸ÃƒÂ¼m kutusu temizlendi" -ForegroundColor $Tema.Basari
    }
    catch {
        if ($_.Exception.Message -match "belirtilen yolu bulamÃ„Â±yor" -or
            $_.Exception.Message -match "cannot find the path" -or
            $_.Exception.Message -match "Recycle Bin.*empty" -or
            $_.Exception.Message -match "boÃ…Å¸") {
            Write-Host "  Ã¢Å“â€œ  Geri dÃƒÂ¶nÃƒÂ¼Ã…Å¸ÃƒÂ¼m kutusu temizlendi" -ForegroundColor $Tema.Basari
        }
        else {
            Write-Host "  Ã¢Å“â€”  Geri dÃƒÂ¶nÃƒÂ¼Ã…Å¸ÃƒÂ¼m kutusu boÃ…Å¸altÃ„Â±lamadÃ„Â±: $($_.Exception.Message)" -ForegroundColor $Tema.Hata
        }
    }

    Write-Host ""
    Read-Host "  Devam etmek iÃƒÂ§in Enter'a basÃ„Â±n"
}
function Clean-Disk {
    Show-Header "DÃ„Â°SK TEMÃ„Â°ZLEME ARACI (cleanmgr)"
    try {
        Start-Process cleanmgr -ArgumentList "/sagerun:1" -Wait
        Write-Result $true "Disk Temizleme aracÃ„Â± ÃƒÂ§alÃ„Â±Ã…Å¸tÃ„Â±rÃ„Â±ldÃ„Â±."
    } catch {
        Write-Result $false "Disk Temizleme ÃƒÂ§alÃ„Â±Ã…Å¸tÃ„Â±rÃ„Â±lamadÃ„Â±: $($_.Exception.Message)"
    }
    Write-Host ""
    Read-Host "  Devam etmek iÃƒÂ§in Enter'a basÃ„Â±n"
}
function Clean-GpuLeftovers {
    Show-Header "EKRAN KARTI SÃƒÅ“RÃƒÅ“CÃƒÅ“ ARTIKLARINI TEMÃ„Â°ZLE"

    Write-Host "  Bu iÃ…Å¸lem AMD / NVIDIA / Intel kurulum artÃ„Â±klarÃ„Â±nÃ„Â± temizler." -ForegroundColor $Tema.Metin
    Write-Host "  (YÃƒÂ¼klÃƒÂ¼ sÃƒÂ¼rÃƒÂ¼cÃƒÂ¼ler etkilenmez, yalnÃ„Â±zca kurulum klasÃƒÂ¶rleri)" -ForegroundColor $Tema.Soluk
    Write-Host ""

    if (-not (Confirm-Islem "SÃƒÂ¼rÃƒÂ¼cÃƒÂ¼ kurulum artÃ„Â±klarÃ„Â± temizlensin mi?")) {
        Write-Result $false "Ã„Â°Ã…Å¸lem iptal edildi."
        Read-Host "  Devam etmek iÃƒÂ§in Enter'a basÃ„Â±n"
        return
    }

    $hedefler = @(
        "C:\AMD",
        "C:\NVIDIA",
        "$env:WINDIR\Temp\NVIDIA Corporation",
        "$env:LOCALAPPDATA\Temp\NVIDIA Corporation",
        "C:\Intel"
    )

    $yasakli = @("C:\", "C:\Windows", $env:WINDIR, $env:SystemRoot, "C:\Program Files", "C:\Program Files (x86)")

    $kazanc = 0
    Write-Host ""

    foreach ($h in $hedefler) {
        if ([string]::IsNullOrWhiteSpace($h) -or -not (Test-Path $h)) {
            Write-Result $true ((Split-Path $h -Leaf) + " klasÃƒÂ¶rÃƒÂ¼ yok, atlandÃ„Â±.")
            continue
        }

        $tam = (Resolve-Path $h -ErrorAction SilentlyContinue).Path
        if ($tam -and ($yasakli -contains $tam.TrimEnd('\'))) {
            Write-Result $false ("GÃƒÅ“VENLÃ„Â°K nedeniyle atlandÃ„Â±: " + $tam)
            continue
        }

        $ad = Split-Path $h -Leaf
        $oncesi = Get-FolderSizeMB $h
        try {
            Remove-Item -Path $h -Recurse -Force -ErrorAction SilentlyContinue
            $kazanc += $oncesi
            Write-Result $true ($ad + " kurulum artÃ„Â±klarÃ„Â± temizlendi.")
        } catch {
            Write-Result $false ($ad + " temizlenirken hata: " + $_.Exception.Message)
        }
    }

    Write-Host ""
    Write-Host ("  " + ("-" * 50)) -ForegroundColor $Tema.Cerceve
    Write-Result $true ("Toplam temizlenen alan: $kazanc MB")

    Write-Host ""
    Read-Host "  Devam etmek iÃƒÂ§in Enter'a basÃ„Â±n"
}
# ==================================================================================
#  HÃ„Â°BRÃ„Â°T PROTECT-USB  (v3.2)
# ==================================================================================
function Protect-USB {
    Show-Header "USB DÃ„Â°SK KORUMA / BÃ„Â°Ãƒâ€¡Ã„Â°MLENDÃ„Â°RME (HÃ„Â°BRÃ„Â°T v3.2)"

    $diskler = Get-Disk | Where-Object { $_.BusType -eq 'USB' }
    if (-not $diskler) {
        Write-Host "  BaÃ„Å¸lÃ„Â± USB disk bulunamadÃ„Â±." -ForegroundColor $Tema.Hata
        Write-Host ""
        Read-Host "  Devam etmek iÃƒÂ§in Enter'a basÃ„Â±n"
        return
    }

    Write-Host "  BaÃ„Å¸lÃ„Â± USB diskler:" -ForegroundColor $Tema.Vurgu
    Write-Host ""
    foreach ($d in $diskler) {
        $boyutGB = [math]::Round($d.Size / 1GB, 1)
        Write-Host ("   Disk {0}  |  {1}  |  {2} GB" -f $d.Number, $d.FriendlyName, $boyutGB) -ForegroundColor $Tema.Metin
    }
    Write-Host ""

    $secim = Read-Host "  Ã„Â°Ã…Å¸lem yapÃ„Â±lacak disk numarasÃ„Â±nÃ„Â± girin (iptal iÃƒÂ§in q)"
    if ($secim -eq 'q' -or [string]::IsNullOrWhiteSpace($secim)) {
        Write-Result $false "Ã„Â°Ã…Å¸lem iptal edildi."
        Read-Host "  Devam etmek iÃƒÂ§in Enter'a basÃ„Â±n"
        return
    }

    $diskNo = 0
    if (-not [int]::TryParse($secim, [ref]$diskNo)) {
        Write-Result $false "GeÃƒÂ§ersiz disk numarasÃ„Â±."
        Read-Host "  Devam etmek iÃƒÂ§in Enter'a basÃ„Â±n"
        return
    }

    $hedefDisk = $diskler | Where-Object { $_.Number -eq $diskNo }
    if (-not $hedefDisk) {
        Write-Result $false "Belirtilen numarada USB disk bulunamadÃ„Â±."
        Read-Host "  Devam etmek iÃƒÂ§in Enter'a basÃ„Â±n"
        return
    }

    if ($hedefDisk.BusType -ne 'USB') {
        Write-Host "  Ã¢Å¡Â  UYARI: Bu disk USB deÃ„Å¸il! Ã„Â°Ã…Å¸lem gÃƒÂ¼venlik nedeniyle durduruldu." -ForegroundColor $Tema.Hata
        Write-Host ""
        Read-Host "  Devam etmek iÃƒÂ§in Enter'a basÃ„Â±n"
        return
    }

    $diskBoyutGB = [math]::Round($hedefDisk.Size / 1GB, 1)
    if ($diskBoyutGB -gt 512) {
        Write-Host "  Ã¢Å¡Â  UYARI: Disk ÃƒÂ§ok bÃƒÂ¼yÃƒÂ¼k ($diskBoyutGB GB). Harici HDD olabilir." -ForegroundColor $Tema.Hata
        if (-not (Confirm-Islem "Yine de devam edilsin mi?")) {
            Write-Result $false "Ã„Â°Ã…Å¸lem iptal edildi."
            Read-Host "  Devam etmek iÃƒÂ§in Enter'a basÃ„Â±n"
            return
        }
    }

    Write-Host ""
    Write-Host ("  SeÃƒÂ§ilen: Disk {0} - {1} ({2} GB)" -f $hedefDisk.Number, $hedefDisk.FriendlyName, $diskBoyutGB) -ForegroundColor $Tema.Vurgu
    Write-Host ""
    Write-Host "  Ne yapmak istersiniz?" -ForegroundColor $Tema.Baslik
    Write-Host "   1) GÃƒÅ“VENLÃ„Â° HALE GETÃ„Â°R + biÃƒÂ§imlendir (TÃƒÅ“M VERÃ„Â° SÃ„Â°LÃ„Â°NÃ„Â°R, autorun korumasÃ„Â± eklenir)" -ForegroundColor $Tema.Metin
    Write-Host "   2) BÃƒÂ¶lÃƒÂ¼mleri listele (salt okuma, gÃƒÂ¼venli)" -ForegroundColor $Tema.Metin
    Write-Host "   q) Ã„Â°ptal" -ForegroundColor $Tema.Soluk
    Write-Host ""

    $islemTipi = Read-Host "  SeÃƒÂ§iminiz"

    switch ($islemTipi) {
        "1" {
            Write-Host ""
            Write-Host ("  " + ("Ã¢â€¢Â" * 50)) -ForegroundColor $Tema.Hata
            Write-Host "  Ã¢Å¡Â  KALICI VERÃ„Â° SÃ„Â°LME + KORUMA Ã„Â°Ã…ÂLEMÃ„Â°" -ForegroundColor $Tema.Hata
            Write-Host ("   Disk   : {0}" -f $hedefDisk.FriendlyName) -ForegroundColor $Tema.Metin
            Write-Host ("   Boyut  : {0} GB" -f $diskBoyutGB) -ForegroundColor $Tema.Metin
            Write-Host "   Silinecek: Diskteki TÃƒÅ“M bÃƒÂ¶lÃƒÂ¼mler ve veriler" -ForegroundColor $Tema.Metin
            Write-Host ("  " + ("Ã¢â€¢Â" * 50)) -ForegroundColor $Tema.Hata
            Write-Host ""

            $onay = Read-Host "  Onaylamak iÃƒÂ§in diskin adÃ„Â±nÃ„Â± yazÃ„Â±n ('$($hedefDisk.FriendlyName)')"
            if ($onay -ne $hedefDisk.FriendlyName) {
                Write-Result $false "Disk adÃ„Â± eÃ…Å¸leÃ…Å¸medi. Ã„Â°Ã…Å¸lem gÃƒÂ¼venlik nedeniyle iptal edildi."
                Read-Host "  Devam etmek iÃƒÂ§in Enter'a basÃ„Â±n"
                return
            }

            try {
                Write-Host ""
                Write-Host "  Ã„Â°Ã…Å¸lem yapÃ„Â±lÃ„Â±yor, lÃƒÂ¼tfen bekleyin..." -ForegroundColor $Tema.Vurgu

                $eskiBolum = Get-Partition -DiskNumber $diskNo -ErrorAction SilentlyContinue |
                             Where-Object DriveLetter | Select-Object -First 1
                $eskiEtiket = if ($eskiBolum) { (Get-Volume -Partition $eskiBolum).FileSystemLabel } else { "" }
                if ([string]::IsNullOrWhiteSpace($eskiEtiket)) { $eskiEtiket = $hedefDisk.FriendlyName }
                if ([string]::IsNullOrWhiteSpace($eskiEtiket)) { $eskiEtiket = "USB" }

                $eskiEtiket = ($eskiEtiket -replace '[\\/:*?"<>|]', '').Trim()
                if ([string]::IsNullOrWhiteSpace($eskiEtiket)) { $eskiEtiket = "USB" }
                if ($eskiEtiket.Length -gt 32) { $eskiEtiket = $eskiEtiket.Substring(0, 32).Trim() }

                Clear-Disk -Number $diskNo -RemoveData -RemoveOEM -Confirm:$false -ErrorAction Stop
                Initialize-Disk -Number $diskNo -PartitionStyle MBR -ErrorAction SilentlyContinue
                New-Partition -DiskNumber $diskNo -UseMaximumSize -AssignDriveLetter -ErrorAction Stop | Out-Null

                Start-Sleep -Seconds 2
                $yeniBolum = Get-Partition -DiskNumber $diskNo -ErrorAction SilentlyContinue |
                             Where-Object DriveLetter | Select-Object -First 1
                if (-not $yeniBolum -or -not $yeniBolum.DriveLetter) {
                    Write-Result $false "SÃƒÂ¼rÃƒÂ¼cÃƒÂ¼ harfi atanamadÃ„Â±. Diski ÃƒÂ§Ã„Â±karÃ„Â±p yeniden takmayÃ„Â± deneyin veya manuel harf atayÃ„Â±n."
                    Read-Host "  Devam etmek iÃƒÂ§in Enter'a basÃ„Â±n"
                    return
                }

                Format-Volume -Partition $yeniBolum -FileSystem NTFS -NewFileSystemLabel $eskiEtiket -Confirm:$false -ErrorAction Stop | Out-Null
                $harf = $yeniBolum.DriveLetter + ":"

                $guvenliKlasor = "$harf\GÃƒÂ¼venliDosya"
                New-Item -Path $guvenliKlasor -ItemType Directory -Force | Out-Null

                $autorunYolu = "$harf\autorun.inf"
                try {
                    New-Item -Path $autorunYolu -ItemType Directory -Force -ErrorAction Stop | Out-Null
                    attrib +h +s $autorunYolu                                                  
                    icacls $autorunYolu /deny "*S-1-1-0:(OI)(CI)(F)" /Q | Out-Null   
                } catch {
                    Write-Host ("  Ã¢Å¡Â  Autorun korumasÃ„Â± uygulanamadÃ„Â±: " + $_.Exception.Message) -ForegroundColor $Tema.Hata
                }

                icacls "$harf\" /deny "*S-1-1-0:(AD,WD)" /Q | Out-Null
                icacls $guvenliKlasor /grant "*S-1-1-0:(OI)(CI)(F)" /Q | Out-Null

                Write-Host ""
                Write-Result $true ("Ã„Â°Ã…Å¸lem tamamlandÃ„Â±! SÃƒÂ¼rÃƒÂ¼cÃƒÂ¼: " + $harf + "  |  Etiket: " + $eskiEtiket)
                Write-Host "  MÃƒÂ¼kemmel! Ana dizine doÃ„Å¸rudan virÃƒÂ¼s/dosya atÃ„Â±lamaz, ama sÃƒÂ¼rÃƒÂ¼cÃƒÂ¼ normal aÃƒÂ§Ã„Â±lÃ„Â±r." -ForegroundColor $Tema.Basari
                Write-Host ("  TÃƒÂ¼m dosyalarÃ„Â±nÃ„Â±zÃ„Â± '{0}\GÃƒÂ¼venliDosya' iÃƒÂ§ine atmalÃ„Â±sÃ„Â±nÃ„Â±z." -f $harf) -ForegroundColor $Tema.Basari
            } catch {
                Write-Result $false ("Ã„Â°Ã…Å¸lem baÃ…Å¸arÃ„Â±sÃ„Â±z: " + $_.Exception.Message)
            }

            Write-Host ""
            Read-Host "  Devam etmek iÃƒÂ§in Enter'a basÃ„Â±n"
        }

        "2" {
            Write-Host ""
            Write-Host "  Disk ÃƒÂ¼zerindeki bÃƒÂ¶lÃƒÂ¼mler:" -ForegroundColor $Tema.Vurgu
            Write-Host ""
            try {
                $bolumler = Get-Partition -DiskNumber $diskNo -ErrorAction Stop
                foreach ($b in $bolumler) {
                    $bBoyutGB = [math]::Round($b.Size / 1GB, 2)
                    $harf = if ($b.DriveLetter) { $b.DriveLetter + ":" } else { "(harf yok)" }
                    Write-Host ("   BÃƒÂ¶lÃƒÂ¼m {0}  |  {1}  |  {2} GB" -f $b.PartitionNumber, $harf, $bBoyutGB) -ForegroundColor $Tema.Metin
                }
            } catch {
                Write-Result $false ("BÃƒÂ¶lÃƒÂ¼mler listelenemedi: " + $_.Exception.Message)
            }

            Write-Host ""
            Read-Host "  Devam etmek iÃƒÂ§in Enter'a basÃ„Â±n"
        }

        default {
            Write-Result $false "Ã„Â°Ã…Å¸lem iptal edildi."
            Read-Host "  Devam etmek iÃƒÂ§in Enter'a basÃ„Â±n"
        }
    }
}
# ===================== DÃ„Â°SK KONTROL VE ONARIM (chkdsk) =====================
function Repair-Disk {
    Show-Header "SÃ„Â°STEM VE DÃ„Â°SK ONARIMI"

    Write-Host "  YapÃ„Â±lacak iÃ…Å¸lemi seÃƒÂ§in:" -ForegroundColor $Tema.Metin
    Write-Host ""
    Write-Host "   [1] Sistem dosyasÃ„Â± onarÃ„Â±mÃ„Â± (SFC /scannow)" -ForegroundColor $Tema.Metin
    Write-Host "   [2] Sistem gÃƒÂ¶rÃƒÂ¼ntÃƒÂ¼sÃƒÂ¼ onarÃ„Â±mÃ„Â± (DISM RestoreHealth)" -ForegroundColor $Tema.Metin
    Write-Host "   [3] Disk kontrolÃƒÂ¼ (CHKDSK - disk seÃƒÂ§meli)" -ForegroundColor $Tema.Metin
    Write-Host "   [4] Tam Sistem OnarÃ„Â±mÃ„Â± (DISM + SFC Birlikte)" -ForegroundColor $Tema.Vurgu
    Write-Host "   [0] Geri" -ForegroundColor $Tema.Soluk
    Write-Host ""

    $girdi = Read-Host "  SeÃƒÂ§iminiz"

    [int]$anaSecim = 0
    if (-not [int]::TryParse($girdi, [ref]$anaSecim)) {
        Write-Result $false "GeÃƒÂ§ersiz giriÃ…Å¸. LÃƒÂ¼tfen bir sayÃ„Â± girin."
        Read-Host "  Devam etmek iÃƒÂ§in Enter'a basÃ„Â±n"
        return
    }

    switch ($anaSecim) {
        0 { return }

        1 {
            Write-Host ""
            Write-Host "  SFC taramasÃ„Â± baÃ…Å¸latÃ„Â±lÃ„Â±yor..." -ForegroundColor $Tema.Metin
            sfc /scannow
            Write-Host ""
            Read-Host "  Devam etmek iÃƒÂ§in Enter'a basÃ„Â±n"
        }

        2 {
            Write-Host ""
            Write-Host "  DISM onarÃ„Â±mÃ„Â± baÃ…Å¸latÃ„Â±lÃ„Â±yor..." -ForegroundColor $Tema.Metin
            DISM /Online /Cleanup-Image /RestoreHealth
            Write-Host ""
            Read-Host "  Devam etmek iÃƒÂ§in Enter'a basÃ„Â±n"
        }

        4 {
            Write-Host ""
            Write-Host "  SFC + DISM sÃ„Â±rayla ÃƒÂ§alÃ„Â±Ã…Å¸tÃ„Â±rÃ„Â±lÃ„Â±yor..." -ForegroundColor $Tema.Metin
            sfc /scannow
            DISM /Online /Cleanup-Image /RestoreHealth
            Write-Host ""
            Read-Host "  Devam etmek iÃƒÂ§in Enter'a basÃ„Â±n"
        }

        3 {
            Invoke-ChkdskSecmeli
        }

        default {
            Write-Result $false "GeÃƒÂ§ersiz seÃƒÂ§im: $anaSecim"
            Read-Host "  Devam etmek iÃƒÂ§in Enter'a basÃ„Â±n"
        }
    }
}
function Invoke-ChkdskSecmeli {
    Show-Header "DÃ„Â°SK KONTROLÃƒÅ“ (CHKDSK)"

    try {
        $diskler = Get-Disk | Sort-Object Number -ErrorAction Stop
    } catch {
        Write-Result $false "Disk bilgisi alÃ„Â±namadÃ„Â±: $($_.Exception.Message)"
        Write-Host ""; Read-Host "  Devam etmek iÃƒÂ§in Enter'a basÃ„Â±n"; return
    }

    if (-not $diskler) {
        Write-Result $false "HiÃƒÂ§ disk bulunamadÃ„Â±."
        Write-Host ""; Read-Host "  Devam etmek iÃƒÂ§in Enter'a basÃ„Â±n"; return
    }

    $secilen = $null
    while (-not $secilen) {

        $harfListesi = @()
        $sayac = 0

        Write-Host ""
        foreach ($disk in $diskler) {
            $model    = if ($disk.FriendlyName) { $disk.FriendlyName.Trim() } else { 'Bilinmeyen' }
            $busType  = if ($disk.BusType) { $disk.BusType } else { '?' }
            $boyutGB  = [math]::Round($disk.Size / 1GB, 2)
            $sistemMi = if ($disk.IsBoot -or $disk.IsSystem) { ' [SÃ„Â°STEM DÃ„Â°SKÃ„Â°]' } else { '' }

            Write-Host ("  [Disk $($disk.Number)] $model") -ForegroundColor $Tema.Baslik
            Write-Host ("     $busType - $boyutGB GB$sistemMi") -ForegroundColor $Tema.Soluk

            $bolumler = Get-Partition -DiskNumber $disk.Number -ErrorAction SilentlyContinue |
                        Where-Object { $_.DriveLetter }

            if (-not $bolumler) {
                Write-Host "        (harflendirilmiÃ…Å¸ bÃƒÂ¶lÃƒÂ¼m yok)" -ForegroundColor $Tema.Soluk
                Write-Host ""
                continue
            }

            foreach ($bolum in $bolumler) {
                $harf     = $bolum.DriveLetter
                $vol      = Get-Volume -DriveLetter $harf -ErrorAction SilentlyContinue
                $etiket   = if ($vol.FileSystemLabel) { $vol.FileSystemLabel } else { 'etiket yok' }
                $fs       = if ($vol.FileSystem) { $vol.FileSystem } else { '?' }
                $bolBoyut = if ($vol.Size) { [math]::Round($vol.Size / 1GB, 2) } else { 0 }
                $sysMi    = if ($harf -eq $env:SystemDrive.TrimEnd(':')) { ' [SÃ„Â°STEM]' } else { '' }

                $sayac++
                $harfListesi += [PSCustomObject]@{
                    No     = $sayac
                    Harf   = $harf
                    Etiket = $etiket
                    FS     = $fs
                    Boyut  = $bolBoyut
                    DiskNo = $disk.Number
                    Model  = $model
                    Sistem = ($harf -eq $env:SystemDrive.TrimEnd(':'))
                }

                Write-Host ("     $sayac) $harf`: $etiket - $bolBoyut GB - $fs$sysMi") -ForegroundColor $Tema.Metin
            }
            Write-Host ""
        }

        if ($sayac -eq 0) {
            Write-Result $false "Taranabilecek harflendirilmiÃ…Å¸ bÃƒÂ¶lÃƒÂ¼m yok."
            Write-Host ""; Read-Host "  Devam etmek iÃƒÂ§in Enter'a basÃ„Â±n"; return
        }

        $girdiSecim = Read-Host "  Taramak istediÃ„Å¸in bÃƒÂ¶lÃƒÂ¼m numarasÃ„Â± (Ã„Â°ptal iÃƒÂ§in 0)"

        [int]$secim = 0
        if (-not [int]::TryParse($girdiSecim, [ref]$secim)) {
            Write-Result $false "GeÃƒÂ§ersiz giriÃ…Å¸. SayÃ„Â± girmelisiniz. Tekrar deneyin."
            continue   
        }
        if ($secim -eq 0) {
            Write-Result $false "Ã„Â°Ã…Å¸lem iptal edildi."
            Write-Host ""; Read-Host "  Devam etmek iÃƒÂ§in Enter'a basÃ„Â±n"; return
        }

        $aday = $harfListesi | Where-Object { $_.No -eq $secim }
        if (-not $aday) {
            Write-Result $false "GeÃƒÂ§ersiz seÃƒÂ§im ($secim). Listeden bir numara seÃƒÂ§in."
            Write-Host ""
            continue   
        }

        if ($aday.Etiket -and $aday.Etiket -ne 'etiket yok') {
            $adGoster = "$($aday.Model) [$($aday.Etiket)]"
        } else {
            $adGoster = $aday.Model
        }
        $secimAdi = "[Disk $($aday.DiskNo)] $($aday.Harf): $adGoster - $($aday.Boyut) GB - $($aday.FS)"

        Write-Host ""
        Write-Host "  Ã¢â€“Â¸ SeÃƒÂ§ilen: $secimAdi" -ForegroundColor $Tema.Vurgu
        Write-Host ""

        $dogruMu = Read-Host "  Bu bÃƒÂ¶lÃƒÂ¼m doÃ„Å¸ru mu? (E = evet devam / H = hayÃ„Â±r tekrar seÃƒÂ§)"
        if ($dogruMu.ToUpper() -ne 'E') {
            Write-Host "  Tekrar seÃƒÂ§im yapabilirsiniz..." -ForegroundColor $Tema.Soluk
            continue   
        }

        $secilen = $aday   
    }

    $harf = $secilen.Harf
    $fs   = $secilen.FS

    if ($fs -in @('exFAT', 'FAT', 'FAT32')) {
        Write-Host ""
        Write-Host "  UYARI: $secimAdi" -ForegroundColor Yellow
        Write-Host "  $fs formatÃ„Â±nda chkdsk sÃ„Â±nÃ„Â±rlÃ„Â± ÃƒÂ§alÃ„Â±Ã…Å¸Ã„Â±r (/R yok)." -ForegroundColor $Tema.Soluk
        Write-Host ""
    }

    Write-Host "  Tarama modu seÃƒÂ§:" -ForegroundColor $Tema.Baslik
    Write-Host "     1) HÃ„Â±zlÃ„Â±  (/F /X) - hatalarÃ„Â± dÃƒÂ¼zelt" -ForegroundColor $Tema.Metin
    Write-Host "     2) Derin  (/R /X) - bozuk sektÃƒÂ¶r (ÃƒÂ§ok uzun)" -ForegroundColor $Tema.Metin
    Write-Host ""
    $modGirdi = Read-Host "  Mod (1/2)"

    if ($fs -in @('exFAT', 'FAT', 'FAT32') -and $modGirdi -eq '2') {
        Write-Result $false "$fs formatÃ„Â±nda /R yok. HÃ„Â±zlÃ„Â± moda geÃƒÂ§iliyor."
        $modGirdi = '1'
    }

    $parametre = if ($modGirdi -eq '2') { '/R /X' } else { '/F /X' }

    if ($secilen.Sistem) {
        Write-Host ""
        Write-Host "  $secimAdi" -ForegroundColor $Tema.Vurgu
        Write-Host "  Bu bir SÃ„Â°STEM sÃƒÂ¼rÃƒÂ¼cÃƒÂ¼sÃƒÂ¼. Ã…Âimdi taranamaz." -ForegroundColor Yellow
        Write-Host "  Yeniden baÃ…Å¸latmada taranacak Ã…Å¸ekilde planlanabilir." -ForegroundColor $Tema.Metin
        Write-Host ""
        $ok = Read-Host "  PlanlansÃ„Â±n mÃ„Â±? (E/H)"
        if ($ok.ToUpper() -eq 'E') {
            cmd /c "echo Y| chkdsk $harf`: $parametre" | Out-Null
            Write-Result $true "$secimAdi Ã¢â€ â€™ yeniden baÃ…Å¸latmada taranacak."
        } else {
            Write-Result $false "Ã„Â°Ã…Å¸lem iptal edildi."
        }
        Write-Host ""; Read-Host "  Devam etmek iÃƒÂ§in Enter'a basÃ„Â±n"; return
    }

    Write-Host ""
    Write-Host "  Ã¢â€“Âº Taranacak: $secimAdi" -ForegroundColor $Tema.Baslik
    Write-Host "  Ã¢â€“Âº Mod: $parametre" -ForegroundColor $Tema.Baslik
    Write-Host "  /X sÃƒÂ¼rÃƒÂ¼cÃƒÂ¼ baÃ„Å¸lantÃ„Â±sÃ„Â±nÃ„Â± geÃƒÂ§ici keser." -ForegroundColor $Tema.Soluk
    Write-Host "  AÃƒÂ§Ã„Â±k dosyalar kapanacak. Devam edilsin mi?" -ForegroundColor $Tema.Metin
    Write-Host ""
    $ok = Read-Host "  Devam? (E/H)"
    if ($ok.ToUpper() -ne 'E') {
        Write-Result $false "Ã„Â°Ã…Å¸lem iptal edildi."
        Write-Host ""; Read-Host "  Devam etmek iÃƒÂ§in Enter'a basÃ„Â±n"; return
    }

    Write-Host ""
    Write-Host "  chkdsk ÃƒÂ§alÃ„Â±Ã…Å¸Ã„Â±yor: $secimAdi" -ForegroundColor Cyan
    Write-Host "  LÃƒÂ¼tfen bekleyin..." -ForegroundColor $Tema.Soluk
    Write-Host ""

    $arguman = "$harf`: $parametre"         
    $sonuc = Start-Process -FilePath "chkdsk.exe" `
                           -ArgumentList $arguman `
                           -NoNewWindow -Wait -PassThru

    Write-Host ""
    if ($sonuc.ExitCode -eq 0) {
        Write-Result $true "$secimAdi Ã¢â€ â€™ temiz, hata bulunamadÃ„Â±."
    } elseif ($sonuc.ExitCode -eq 1) {
        Write-Result $true "$secimAdi Ã¢â€ â€™ hatalar bulundu ve dÃƒÂ¼zeltildi."
    } else {
        Write-Result $false "$secimAdi Ã¢â€ â€™ tarama bitti (Kod: $($sonuc.ExitCode))."
    }

    Write-Host ""
    Read-Host "  Devam etmek iÃƒÂ§in Enter'a basÃ„Â±n"
}

# ===================== SÃƒÅ“RÃƒÅ“CÃƒÅ“ VE UYGULAMA YÃƒâ€“NETÃ„Â°MÃ„Â° =====================

function Backup-Drivers {
    Show-Header "SÃƒÅ“RÃƒÅ“CÃƒÅ“ YEDEKLE"
    $hedef = Select-Folder "SÃƒÂ¼rÃƒÂ¼cÃƒÂ¼lerin yedekleneceÃ„Å¸i klasÃƒÂ¶rÃƒÂ¼ seÃƒÂ§in"
    if (-not $hedef) { Write-Result $false "Ã„Â°Ã…Å¸lem iptal edildi."; Write-Host ""; Read-Host "  Devam etmek iÃƒÂ§in Enter'a basÃ„Â±n"; return }

    $klasor = Join-Path $hedef ("Surucu_Yedek_" + (Get-Date -Format "yyyyMMdd_HHmm"))
    Write-Host ""
    $onay = Read-Host "  SÃƒÂ¼rÃƒÂ¼cÃƒÂ¼ler '$klasor' klasÃƒÂ¶rÃƒÂ¼ne yedeklenecek. OnaylÃ„Â±yor musunuz? (E/H)"
    if ($onay -ne "E" -and $onay -ne "e") {
        Write-Result $false "Ã„Â°Ã…Å¸lem iptal edildi."; Write-Host ""; Read-Host "  Devam etmek iÃƒÂ§in Enter'a basÃ„Â±n"; return
    }

    $eskiProgress = $ProgressPreference
    $ProgressPreference = 'SilentlyContinue'
    try {
        New-Item -Path $klasor -ItemType Directory -Force | Out-Null

        Write-Host "  SÃƒÂ¼rÃƒÂ¼cÃƒÂ¼ler yedekleniyor, lÃƒÂ¼tfen bekleyin..." -ForegroundColor Yellow
        Write-Host "  (Her yedeklenen sÃƒÂ¼rÃƒÂ¼cÃƒÂ¼ canlÃ„Â± listelenecek.)" -ForegroundColor DarkGray
        Write-Host ""

       $sayac = 0
       Export-WindowsDriver -Online -Destination $klasor -ErrorAction Stop | ForEach-Object {
            $sayac++
            $no = $sayac.ToString().PadLeft(3)
            $ad = if ($_.OriginalFileName) { Split-Path $_.OriginalFileName -Leaf } else { "(bilinmeyen sÃƒÂ¼rÃƒÂ¼cÃƒÂ¼)" }
            $sinif = if ($_.ClassName) { $_.ClassName } else { "Genel" }
            Write-Host ("  [" + $no + "] ") -ForegroundColor Cyan -NoNewline
            Write-Host $ad -ForegroundColor Gray -NoNewline
            Write-Host ("   (" + $sinif + ")") -ForegroundColor DarkGray

            Write-Progress -Activity "SÃƒÂ¼rÃƒÂ¼cÃƒÂ¼ler yedekleniyor" `
                           -Status "$sayac sÃƒÂ¼rÃƒÂ¼cÃƒÂ¼ yedeklendi..." `
                           -CurrentOperation $ad
        }
        Write-Progress -Activity "SÃƒÂ¼rÃƒÂ¼cÃƒÂ¼ler yedekleniyor" -Completed

        Write-Host ""
        if ($sayac -gt 0) {
            Write-Result $true "$sayac sÃƒÂ¼rÃƒÂ¼cÃƒÂ¼ yedeklendi: $klasor"
        } else {
            Write-Result $false "Yedeklenecek sÃƒÂ¼rÃƒÂ¼cÃƒÂ¼ bulunamadÃ„Â±."
        }
    } catch {
        Write-Result $false "SÃƒÂ¼rÃƒÂ¼cÃƒÂ¼ yedeklenemedi: $($_.Exception.Message)"
    } finally {
        $ProgressPreference = $eskiProgress
    }
    Write-Host ""
    Read-Host "  Devam etmek iÃƒÂ§in Enter'a basÃ„Â±n"
}

function Restore-Drivers {
    Show-Header "SÃƒÅ“RÃƒÅ“CÃƒÅ“ GERÃ„Â° YÃƒÅ“KLE"
    $kaynak = Select-Folder "YedeklenmiÃ…Å¸ sÃƒÂ¼rÃƒÂ¼cÃƒÂ¼ klasÃƒÂ¶rÃƒÂ¼nÃƒÂ¼ seÃƒÂ§in"
    if (-not $kaynak) { Write-Result $false "Ã„Â°Ã…Å¸lem iptal edildi."; Write-Host ""; Read-Host "  Devam etmek iÃƒÂ§in Enter'a basÃ„Â±n"; return }

    Write-Host ""
    $onay = Read-Host "  SÃƒÂ¼rÃƒÂ¼cÃƒÂ¼ler '$kaynak' klasÃƒÂ¶rÃƒÂ¼nden geri yÃƒÂ¼klenecek. Emin misiniz? (E/H)"
    if ($onay -ne "E" -and $onay -ne "e") {
        Write-Result $false "Ã„Â°Ã…Å¸lem iptal edildi."; Write-Host ""; Read-Host "  Devam etmek iÃƒÂ§in Enter'a basÃ„Â±n"; return
    }
    try {
        $infVar = Get-ChildItem -Path $kaynak -Filter *.inf -Recurse -ErrorAction SilentlyContinue
        if (-not $infVar) {
            Write-Result $false "SeÃƒÂ§ilen klasÃƒÂ¶rde .inf sÃƒÂ¼rÃƒÂ¼cÃƒÂ¼ dosyasÃ„Â± bulunamadÃ„Â±."
            Write-Host ""
            Read-Host "  Devam etmek iÃƒÂ§in Enter'a basÃ„Â±n"
            return
        }

        Write-Host "  SÃƒÂ¼rÃƒÂ¼cÃƒÂ¼ler yÃƒÂ¼kleniyor, lÃƒÂ¼tfen bekleyin..." -ForegroundColor Yellow
        pnputil /add-driver "$kaynak\*.inf" /subdirs /install
        $kod = $LASTEXITCODE

        switch ($kod) {
            0 {
                Write-Result $true "SÃƒÂ¼rÃƒÂ¼cÃƒÂ¼ler geri yÃƒÂ¼klendi."
            }
            259 {
                Write-Result $true "TÃƒÂ¼m sÃƒÂ¼rÃƒÂ¼cÃƒÂ¼ler zaten gÃƒÂ¼ncel Ã¢â‚¬â€ yÃƒÂ¼klenecek yeni sÃƒÂ¼rÃƒÂ¼cÃƒÂ¼ yoktu."
            }
            3010 {
                Write-Result $true "SÃƒÂ¼rÃƒÂ¼cÃƒÂ¼ler geri yÃƒÂ¼klendi. DeÃ„Å¸iÃ…Å¸ikliklerin tamamlanmasÃ„Â± iÃƒÂ§in yeniden baÃ…Å¸latÃ„Â±n."
            }
            default {
                Write-Result $false "SÃƒÂ¼rÃƒÂ¼cÃƒÂ¼ geri yÃƒÂ¼kleme tamamlandÃ„Â± ancak bazÃ„Â± sÃƒÂ¼rÃƒÂ¼cÃƒÂ¼ler yÃƒÂ¼klenemedi (Kod: $kod)."
            }
        }
    } catch {
        Write-Result $false "SÃƒÂ¼rÃƒÂ¼cÃƒÂ¼ geri yÃƒÂ¼klenemedi: $($_.Exception.Message)"
    }
    Write-Host ""
    Read-Host "  Devam etmek iÃƒÂ§in Enter'a basÃ„Â±n"
}

# ===================== UYGULAMA ARA VE KUR (winget search) =====================
function Search-App {
    Show-Header "UYGULAMA ARA (winget)"

    $arama = Read-Host "  Aranacak uygulama adi (Iptal icin bos Enter)"
    if ([string]::IsNullOrWhiteSpace($arama)) {
        Write-Host "  Islem iptal edildi." -ForegroundColor $Tema.Soluk
        Read-Host "  Devam etmek icin Enter'a basin"
        return
    }

    $storeVar = $null -ne (Get-AppxPackage -Name "Microsoft.WindowsStore" -ErrorAction SilentlyContinue)
    if ($storeVar) {
        Write-Host "  Sistem: Normal (Store'lu)" -ForegroundColor $Tema.Metin
    } else {
        Write-Host "  Sistem: Store yok (sadece winget kaynaklari)" -ForegroundColor $Tema.Metin
    }

    Write-Host ""
    Write-Host "  '$arama' araniyor..." -ForegroundColor $Tema.Vurgu
    Write-Host ""

    $sonuc = winget search $arama 2>&1 | Out-String

    $temizSatirlar = foreach ($satir in ($sonuc -split "`r?`n")) {
        $t = $satir.Trim()
        if ($t -match '^[\\/|\-]+$') { continue }
        $satir
    }
    $sonuc = ($temizSatirlar -join "`r`n").Trim()

    Write-Host $sonuc -ForegroundColor $Tema.Metin
    Write-Host ""

    if ($storeVar) {
        Write-Host "  Bilgi: Store mevcut. Tum paketler kurulabilir." -ForegroundColor $Tema.Soluk
    }
    Write-Host ""

    $id = Read-Host "  Kurmak icin uygulama ID'sini yazin (atlamak icin bos Enter)"
    if ([string]::IsNullOrWhiteSpace($id)) {
        Write-Host "  Kurulum atlandi." -ForegroundColor $Tema.Soluk
        Read-Host "  Devam etmek icin Enter'a basin"
        return
    }
    $id = $id.Trim()

    $secilenAd = $id   
    foreach ($satir in ($sonuc -split "`r?`n")) {
        if ($satir -match [regex]::Escape($id)) {
            $idKonum = $satir.IndexOf($id)
            if ($idKonum -gt 0) {
                $adKismi = $satir.Substring(0, $idKonum).Trim()
                if ($adKismi) { $secilenAd = $adKismi }
            }
            break
        }
    }

    Write-Host ""
    Write-Host "  '$secilenAd' kuruluyor..." -ForegroundColor $Tema.Vurgu
    Write-Host ""

    winget install --id $id --accept-package-agreements --accept-source-agreements

    if ($LASTEXITCODE -eq -2147023143) {
        Write-Host "  Firewall servisi kapali. Baslatiliyor..." -ForegroundColor $Tema.Hata
        Start-Service BFE, mpssvc, Winmgmt -ErrorAction SilentlyContinue
        Write-Host "  Tekrar deneniyor..." -ForegroundColor $Tema.Vurgu
        winget install --id $id --accept-package-agreements --accept-source-agreements
    }

    Write-Host ""

    if ($LASTEXITCODE -eq 0 -or $LASTEXITCODE -eq -1978335189) {
        Write-Result $true "'$secilenAd' basariyla kuruldu."
    } elseif ($LASTEXITCODE -eq -1978335212) {
        Write-Result $false "'$secilenAd' bulunamadi. ID'yi kontrol edin."
    } else {
        Write-Result $false "'$secilenAd' kurulamadi. (Hata kodu: $LASTEXITCODE)"
    }

    Write-Host ""
    Write-Host "  Ipucu: Kaldirmak icin ana menuden 'Uygulama Kaldir' secenegini kullanin." -ForegroundColor $Tema.Soluk
    Read-Host "  Devam etmek icin Enter'a basin"
}
function App-ExportImport {
    Show-Header "UYGULAMA LÃ„Â°STESÃ„Â° DIÃ…ÂA/Ã„Â°Ãƒâ€¡E AKTAR"
    Write-Host "  1) YÃƒÂ¼klÃƒÂ¼ uygulama listesini dÃ„Â±Ã…Å¸a aktar (JSON)" -ForegroundColor White
    Write-Host "  2) JSON dosyasÃ„Â±ndan uygulamalarÃ„Â± iÃƒÂ§e aktar (kur)" -ForegroundColor White
    Write-Host ""

    if (-not $WingetVar) {
        Write-Result $false "Winget bulunamadÃ„Â±, bu iÃ…Å¸lem yapÃ„Â±lamÃ„Â±yor."
        Write-Host ""
        Read-Host "  Devam etmek iÃƒÂ§in Enter'a basÃ„Â±n"
        return
    }

    $sec = Read-Host "  SeÃƒÂ§iminiz (1/2)"
    if ($sec -eq "1") {
        $hedef = Select-Folder "JSON'un kaydedileceÃ„Å¸i klasÃƒÂ¶rÃƒÂ¼ seÃƒÂ§in"
        if ($hedef) {
            $dosya = Join-Path $hedef "uygulama_listesi.json"
            winget export -o "$dosya" --accept-source-agreements | Out-Null
            if (Test-Path $dosya) {
                $boyutKB = [math]::Round((Get-Item $dosya).Length / 1KB, 1)
                Write-Result $true "Liste dÃ„Â±Ã…Å¸a aktarÃ„Â±ldÃ„Â±: $dosya ($boyutKB KB)"
            } else {
                Write-Result $false "DÃ„Â±Ã…Å¸a aktarma baÃ…Å¸arÃ„Â±sÃ„Â±z: dosya oluÃ…Å¸turulamadÃ„Â±."
            }
        } else {
            Write-Result $false "Ã„Â°Ã…Å¸lem iptal edildi."
        }
    } elseif ($sec -eq "2") {
        $dosya = Select-File
        if ($dosya) {

            $gecerli = $false
            try {
                $icerik = Get-Content $dosya -Raw -ErrorAction Stop
                if (-not [string]::IsNullOrWhiteSpace($icerik)) {
                    $null = $icerik | ConvertFrom-Json -ErrorAction Stop
                    $gecerli = $true
                }
            } catch {
                $gecerli = $false
            }

            if (-not $gecerli) {
                Write-Result $false "SeÃƒÂ§ilen dosya geÃƒÂ§erli bir JSON deÃ„Å¸il veya boÃ…Å¸. Ã„Â°Ã…Å¸lem durduruldu."
                Write-Host ""
                Read-Host "  Devam etmek iÃƒÂ§in Enter'a basÃ„Â±n"
                return
            }

            $onay = Read-Host "  '$dosya' iÃƒÂ§indeki uygulamalar kurulacak. OnaylÃ„Â±yor musunuz? (E/H)"
            if ($onay -eq "E" -or $onay -eq "e") {

                Write-Host ""
                Write-Host "  LÃƒÂ¼tfen bekleyin, uygulamalar kuruluyor (canlÃ„Â± akacak)..." -ForegroundColor DarkGray
                Write-Host ""

                $geciciDosya = Join-Path $env:TEMP "winget_import_log.txt"

                winget import -i "$dosya" --disable-interactivity `
                    --accept-package-agreements --accept-source-agreements --ignore-unavailable 2>&1 |
                    Tee-Object -FilePath $geciciDosya
                $kod = $LASTEXITCODE

                $ham = ""
                if (Test-Path $geciciDosya) { $ham = Get-Content $geciciDosya -Raw }
                Remove-Item $geciciDosya -ErrorAction SilentlyContinue

                $zatenKurulu = ([regex]::Matches($ham, "already installed")).Count
                $yeniKurulan = ([regex]::Matches($ham, "Successfully installed")).Count
                $toplam      = $zatenKurulu + $yeniKurulan

                Write-Host ""
                Show-Top
                Show-Line "  Ã„Â°Ãƒâ€¡E AKTARMA Ãƒâ€“ZETÃ„Â°" $Tema.Vurgu
                Show-Divider
                Show-Line ("  Zaten kurulu      : " + $zatenKurulu + " uygulama") $Tema.Metin
                Show-Line ("  Yeni kurulan      : " + $yeniKurulan + " uygulama") $Tema.Basari
                Show-Divider
                Show-Line ("  Ã„Â°Ã…Å¸lenen toplam    : " + $toplam + " uygulama") $Tema.Baslik
                Show-Bottom
                Write-Host ""

                if ($kod -eq 0) {
                    if ($yeniKurulan -gt 0) {
                        Write-Result $true "$yeniKurulan uygulama yeni kuruldu, $zatenKurulu uygulama zaten kuruluydu."
                    } else {
                        Write-Result $true "TÃƒÂ¼m uygulamalar ($zatenKurulu) zaten kuruluydu Ã¢â‚¬â€ yeni kurulum gerekmedi."
                    }
                } else {
                    Write-Result $false "Ã„Â°ÃƒÂ§e aktarma tamamlandÃ„Â± ancak bazÃ„Â± uygulamalar kurulamadÃ„Â± (Kod: $kod)."
                }
            } else {
                Write-Result $false "Ã„Â°Ã…Å¸lem iptal edildi."
            }
        } else {
            Write-Result $false "Ã„Â°Ã…Å¸lem iptal edildi."
        }
    } else {
        Write-Result $false "GeÃƒÂ§ersiz seÃƒÂ§im."
    }
    Write-Host ""
    Read-Host "  Devam etmek iÃƒÂ§in Enter'a basÃ„Â±n"
}
function App-Uninstall {
    Show-Header "UYGULAMA KALDIR"
    Write-Host "  YÃƒÂ¼klÃƒÂ¼ tÃƒÂ¼m uygulamalar listeleniyor..." -ForegroundColor Yellow
    Write-Host ""
    if (-not $WingetVar) {
        Write-Result $false "Winget bulunamadÃ„Â±."
        Write-Host ""
        Read-Host "  Devam etmek iÃƒÂ§in Enter'a basÃ„Â±n"
        return
    }
    winget list
    Write-Host ""
    Write-Host "  YukarÃ„Â±daki listeden kaldÃ„Â±rmak istediÃ„Å¸iniz uygulamanÃ„Â±n" -ForegroundColor Cyan
    Write-Host "  ID veya Ad bilgisini girin (boÃ…Å¸ bÃ„Â±rakÃ„Â±p Enter = iptal)." -ForegroundColor Cyan
    Write-Host ""
    $hedef = Read-Host "  KaldÃ„Â±rÃ„Â±lacak uygulama (ID veya Ad)"
    if ([string]::IsNullOrWhiteSpace($hedef)) {
        Write-Result $false "Ã„Â°Ã…Å¸lem iptal edildi."
        Write-Host ""; Read-Host "  Devam etmek iÃƒÂ§in Enter'a basÃ„Â±n"; return
    }

    $gercekAd = $hedef

    $onay = Read-Host "  '$hedef' kaldÃ„Â±rÃ„Â±lsÃ„Â±n mÃ„Â±? (E/H)"
    if ($onay -ne "E" -and $onay -ne "e") {
        Write-Result $false "Ã„Â°Ã…Å¸lem iptal edildi."
        Write-Host ""; Read-Host "  Devam etmek iÃƒÂ§in Enter'a basÃ„Â±n"; return
    }

    try {
        $oncesi = (winget list --id $hedef 2>$null | Out-String)
        $varOncesiId = $oncesi -match [regex]::Escape($hedef)
        if (-not $varOncesiId) {
            $oncesiAd = (winget list --name $hedef 2>$null | Out-String)
            $varOncesiId = $oncesiAd -match [regex]::Escape($hedef)
        }

        $ciktiId = (winget uninstall --id $hedef --silent --accept-source-agreements 2>&1 | Out-String)
        $kod = $LASTEXITCODE
        $ciktiTum = $ciktiId

        if ($kod -ne 0) {
            Write-Host "  ID ile bulunamadÃ„Â±, Ad ile deneniyor..." -ForegroundColor DarkGray
            $ciktiAd = (winget uninstall --name $hedef --silent --accept-source-agreements 2>&1 | Out-String)
            $kod = $LASTEXITCODE
            $ciktiTum = $ciktiId + "`n" + $ciktiAd
        }

        $eslesme = [regex]::Match($ciktiTum, '(?im)^\s*(?:Found|Bulundu)\s+(?<ad>.+?)\s+\[[^\]]+\]\s*$')
        if ($eslesme.Success) {
            $gercekAd = $eslesme.Groups['ad'].Value.Trim()
        } else {
            $eslesme2 = [regex]::Match($ciktiTum, '(?m)^\s*(?<ad>.+?)\s+\[' + [regex]::Escape($hedef) + '\]')
            if ($eslesme2.Success) { $gercekAd = $eslesme2.Groups['ad'].Value.Trim() }
        }

        Start-Sleep -Seconds 1
        $sonrasi = (winget list --id $hedef 2>$null | Out-String)
        $halaVar = $sonrasi -match [regex]::Escape($hedef)
        if (-not $halaVar) {
            $sonrasiAd = (winget list --name $hedef 2>$null | Out-String)
            $halaVar = $sonrasiAd -match [regex]::Escape($hedef)
        }

        if (-not $varOncesiId) {
            Write-Result $false "'$gercekAd' zaten yÃƒÂ¼klÃƒÂ¼ deÃ„Å¸ildi (kaldÃ„Â±rÃ„Â±lacak bir Ã…Å¸ey yok)."
        } elseif (-not $halaVar) {
            Write-Result $true "'$gercekAd' baÃ…Å¸arÃ„Â±yla kaldÃ„Â±rÃ„Â±ldÃ„Â± ve doÃ„Å¸rulandÃ„Â±."
        } else {
            Write-Result $false "'$gercekAd' hÃƒÂ¢lÃƒÂ¢ yÃƒÂ¼klÃƒÂ¼ gÃƒÂ¶rÃƒÂ¼nÃƒÂ¼yor (Kod: $kod). KaldÃ„Â±rma tamamlanamadÃ„Â±."
        }
    } catch {
        Write-Result $false "KaldÃ„Â±rma baÃ…Å¸arÃ„Â±sÃ„Â±z: $($_.Exception.Message)"
    }
    Write-Host ""
    Read-Host "  Devam etmek iÃƒÂ§in Enter'a basÃ„Â±n"
}
function Show-Help {
    Show-Header "YARDIM / HAKKINDA"
    Write-Host "  Bilgisayar AracÃ„Â±" -ForegroundColor $Tema.Vurgu
    Write-Host "  HazÃ„Â±rlayan : Mehmet IÃ…ÂIK" -ForegroundColor $Tema.Metin
    Write-Host "  GÃƒÂ¼ncelleme : 04.07.2026" -ForegroundColor $Tema.Metin
    Write-Host ""
    Write-Host "  Bu araÃƒÂ§; uygulama kurulumu, sistem bilgisi," -ForegroundColor $Tema.Metin
    Write-Host "  bakÃ„Â±m/temizlik ve sÃƒÂ¼rÃƒÂ¼cÃƒÂ¼ yÃƒÂ¶netimi saÃ„Å¸lar." -ForegroundColor $Tema.Metin
    Write-Host ""
    Write-Host "  Ã¢â‚¬Â¢ Numara yazÃ„Â±p Enter ile iÃ…Å¸lemi seÃƒÂ§in." -ForegroundColor $Tema.Soluk
    Write-Host "  Ã¢â‚¬Â¢ 0 yazÃ„Â±p Enter ile programdan ÃƒÂ§Ã„Â±kÃ„Â±n." -ForegroundColor $Tema.Soluk
    Write-Host ""
    if ($WingetVar) {
        Write-Host "  Ã¢â‚¬Â¢ Winget (paket yÃƒÂ¶neticisi): YÃƒÅ“KLÃƒÅ“ Ã¢Å“â€œ" -ForegroundColor $Tema.Basari
    } else {
        Write-Host "  Ã¢â‚¬Â¢ Winget (paket yÃƒÂ¶neticisi): YÃƒÅ“KLÃƒÅ“ DEÃ„ÂÃ„Â°L Ã¢Å“â€”" -ForegroundColor $Tema.Hata
        Write-Host "    Kurulum iÃƒÂ§in aÃ…Å¸aÃ„Å¸Ã„Â±dan 'E' seÃƒÂ§ebilirsiniz." -ForegroundColor $Tema.Soluk
    }
    Write-Host ""

    $wh = Read-Host "  Winget kurulum yardÃ„Â±mÃ„Â±nÃ„Â± gÃƒÂ¶rÃƒÂ¼ntÃƒÂ¼lemek ister misiniz? (E/H)"
    if ($wh -eq "E" -or $wh -eq "e") {
        Show-WingetHelp
        $script:WingetVar = ($null -ne (Get-Command winget -ErrorAction SilentlyContinue))
    }
}

# ===================== UYGULAMA KURULUM EKRANI =====================

function Invoke-AppMenu {
    while ($true) {
        Show-Header "UYGULAMA KURULUMU"
        foreach ($u in $Uygulamalar) {
            $numara = "  " + $u.No.ToString().PadLeft(2) + ") "
            $satirAd = $u.Ad
            $tamSatir = $numara + $satirAd
            if ($tamSatir.Length -gt $BoxWidth) { $tamSatir = $tamSatir.Substring(0, $BoxWidth) }
            $bosluk = [math]::Max(1, $BoxWidth - $tamSatir.Length)
            Write-Host "Ã¢â€¢â€˜" -ForegroundColor $Tema.Cerceve -NoNewline
            Write-Host (" " + $numara) -ForegroundColor $Tema.Vurgu -NoNewline
            Write-Host ($satirAd + (" " * ($bosluk - 1))) -ForegroundColor $Tema.Baslik -NoNewline
            Write-Host "Ã¢â€¢â€˜" -ForegroundColor $Tema.Cerceve
        }
        Show-Divider
        Show-Line "  T) SeÃƒÂ§ili numaralarÃ„Â± kur (ÃƒÂ¶rn: 1,3,5)" $Tema.Vurgu
        Show-Line "  H) TÃƒÂ¼mÃƒÂ¼nÃƒÂ¼ kur" $Tema.Vurgu
        Show-Line "  0) Ana menÃƒÂ¼ye dÃƒÂ¶n" $Tema.Soluk
        Show-Bottom
        Write-Host ""
        $sec = Read-Host "  SeÃƒÂ§iminiz"

        if ($sec -eq "0") { return }

        if ($sec -eq "H" -or $sec -eq "h" -or $sec -eq "T" -or $sec -eq "t" -or $sec -match "[0-9]") {
            $secilenNolar = @()
            if ($sec -eq "H" -or $sec -eq "h") {
                $secilenNolar = $Uygulamalar.No
            } else {
                $secilenNolar = ($sec -split "[,\s]+" | Where-Object { $_ -match "^\d+$" } | ForEach-Object { [int]$_ })
            }
            $wingetGerekli = $secilenNolar | Where-Object { $_ -ne 16 }

            if ($wingetGerekli -and -not $WingetVar) {
                Write-Host ""
                Write-Result $false "Winget kurulu olmadÃ„Â±Ã„Å¸Ã„Â± iÃƒÂ§in uygulama kurulumu yapÃ„Â±lamÃ„Â±yor."
                Write-Host ""
                Write-Host "  Winget'i kurmak iÃƒÂ§in ana menÃƒÂ¼ > 26) YardÃ„Â±m bÃƒÂ¶lÃƒÂ¼mÃƒÂ¼nÃƒÂ¼ kullanÃ„Â±n" -ForegroundColor Yellow
                Write-Host "  veya programÃ„Â± yeniden baÃ…Å¸latÃ„Â±n (aÃƒÂ§Ã„Â±lÃ„Â±Ã…Å¸ta otomatik kurulmayÃ„Â± dener)." -ForegroundColor Yellow
                Write-Host ""
                Read-Host "  Devam etmek iÃƒÂ§in Enter'a basÃ„Â±n"
                continue   
            }
        }

        if ($sec -eq "H" -or $sec -eq "h") {
            foreach ($u in $Uygulamalar) {
                Install-App $u.Ad $u.Id $u.Kaynak
            }
            Write-Host ""; Read-Host "  Devam etmek iÃƒÂ§in Enter'a basÃ„Â±n"
        }
        elseif ($sec -eq "T" -or $sec -eq "t" -or $sec -match "[0-9]") {
            $numaralar = $sec -split "[,\s]+" | Where-Object { $_ -match "^\d+$" }
            foreach ($n in $numaralar) {
                $secilen = $Uygulamalar | Where-Object { $_.No -eq [int]$n }
                if ($secilen) {
                    Install-App $secilen.Ad $secilen.Id $secilen.Kaynak
                }
            }
            Write-Host ""; Read-Host "  Devam etmek iÃƒÂ§in Enter'a basÃ„Â±n"
        }
    }
}
# ===================== TEK DÃƒÅ“Z MENÃƒÅ“ (FLAT) =====================
$Menu = @(
    # ===== SOL SÃƒÅ“TUN (1Ã¢â‚¬â€œ14) =====
    @{ No = 1;  Grup = "UYGULAMA";  Ad = "Uygulama Kurulumu (liste)";          Eylem = { Invoke-AppMenu } }
    @{ No = 2;  Grup = "UYGULAMA";  Ad = "TÃƒÂ¼m UygulamalarÃ„Â± GÃƒÂ¼ncelle";          Eylem = { Update-AllApps } }
    @{ No = 3;  Grup = "UYGULAMA";  Ad = "Uygulama Ara ve Kur (winget)";       Eylem = { Search-App } }
    @{ No = 4;  Grup = "UYGULAMA";  Ad = "Uygulama Listesi DÃ„Â±Ã…Å¸a/Ã„Â°ÃƒÂ§e Aktar";    Eylem = { App-ExportImport } }
    @{ No = 5;  Grup = "UYGULAMA";  Ad = "Uygulama KaldÃ„Â±r";                    Eylem = { App-Uninstall } }

    @{ No = 6;  Grup = "TEMÃ„Â°ZLÃ„Â°K";  Ad = "GeÃƒÂ§ici DosyalarÃ„Â± Temizle";           Eylem = { Clean-Temp } }
    @{ No = 7;  Grup = "TEMÃ„Â°ZLÃ„Â°K";  Ad = "Windows LoglarÃ„Â±nÃ„Â± Temizle";          Eylem = { Clean-Logs } }
    @{ No = 8;  Grup = "TEMÃ„Â°ZLÃ„Â°K";  Ad = "Windows Update Ãƒâ€“nbelleÃ„Å¸i";           Eylem = { Clean-WinUpdate } }
    @{ No = 9;  Grup = "TEMÃ„Â°ZLÃ„Â°K";  Ad = "Geri DÃƒÂ¶nÃƒÂ¼Ã…Å¸ÃƒÂ¼m Kutusunu BoÃ…Å¸alt";       Eylem = { Clean-RecycleBin } }
    @{ No = 10; Grup = "TEMÃ„Â°ZLÃ„Â°K";  Ad = "Disk Temizleme (cleanmgr)";          Eylem = { Clean-Disk } }
    @{ No = 11; Grup = "TEMÃ„Â°ZLÃ„Â°K";  Ad = "Ekran KartÃ„Â± SÃƒÂ¼rÃƒÂ¼cÃƒÂ¼ ArtÃ„Â±klarÃ„Â±";       Eylem = { Clean-GpuLeftovers } }

    @{ No = 12; Grup = "SÃƒÅ“RÃƒÅ“CÃƒÅ“";    Ad = "SÃƒÂ¼rÃƒÂ¼cÃƒÂ¼ Yedekle";                     Eylem = { Backup-Drivers } }
    @{ No = 13; Grup = "SÃƒÅ“RÃƒÅ“CÃƒÅ“";    Ad = "SÃƒÂ¼rÃƒÂ¼cÃƒÂ¼ Geri YÃƒÂ¼kle";                  Eylem = { Restore-Drivers } }

    # ===== SAÃ„Â SÃƒÅ“TUN (15Ã¢â‚¬â€œ27) =====
    @{ No = 14; Grup = "BAKIM";     Ad = "Sistem ve Disk OnarÃ„Â±mÃ„Â±";   	       Eylem = { Repair-Disk } }
    @{ No = 15; Grup = "BAKIM";     Ad = "GÃƒÂ¼venli USB OluÃ…Å¸tur (KorumalÃ„Â±)";     Eylem = { Protect-USB } }
    @{ No = 16; Grup = "BAKIM";     Ad = "Windows GÃƒÂ¼ncellemelerini Tara";      Eylem = { Start-WindowsUpdate } }
    @{ No = 17; Grup = "BAKIM";     Ad = "AÃ„Å¸ AyarlarÃ„Â±nÃ„Â± SÃ„Â±fÃ„Â±rla";              Eylem = { Reset-Network } }
    @{ No = 18; Grup = "BAKIM";     Ad = "Geri YÃƒÂ¼kleme NoktasÃ„Â± OluÃ…Å¸tur";       Eylem = { New-RestorePoint } }
    @{ No = 19; Grup = "BAKIM";     Ad = "YazÃ„Â±cÃ„Â± KuyruÃ„Å¸unu Temizle";           Eylem = { Clear-PrintQueue } }

    @{ No = 20; Grup = "BÃ„Â°LGÃ„Â°";     Ad = "Sistem Bilgileri";                   Eylem = { Show-SystemInfo } }
    @{ No = 21; Grup = "BÃ„Â°LGÃ„Â°";     Ad = "Disk Ãƒâ€“zeti";                         Eylem = { Show-DiskSummary } }
    @{ No = 22; Grup = "BÃ„Â°LGÃ„Â°";     Ad = "Disk SaÃ„Å¸lÃ„Â±Ã„Å¸Ã„Â± (SMART)";               Eylem = { Show-DiskHealth } }
    @{ No = 23; Grup = "BÃ„Â°LGÃ„Â°";     Ad = "BaÃ…Å¸langÃ„Â±ÃƒÂ§ ProgramlarÃ„Â±";              Eylem = { Show-Startup } }
    @{ No = 24; Grup = "BÃ„Â°LGÃ„Â°";     Ad = "Sistem SaÃ„Å¸lÃ„Â±k Ãƒâ€“zeti";                Eylem = { Show-HealthSummary } }

    @{ No = 25; Grup = "DÃ„Â°Ã„ÂER";     Ad = "YÃƒÂ¶netim KlasÃƒÂ¶rleri OluÃ…Å¸tur";         Eylem = { New-AdminFolders } }
    @{ No = 26; Grup = "DÃ„Â°Ã„ÂER";     Ad = "YardÃ„Â±m / HakkÃ„Â±nda";                  Eylem = { Show-Help } }
)

# ===================== YARDIMCI: MENÃƒÅ“ KOLONU OLUÃ…ÂTUR =====================
function Get-Kolon {
    param(
        [string[]]$Gruplar,
        [hashtable]$Ikon,
        [array]$MenuListesi
    )
    $satirlar = @()
    foreach ($g in $Gruplar) {
        $ik = if ($Ikon.ContainsKey($g)) { $Ikon[$g] } else { "Ã¢â‚¬Â¢" }
        $satirlar += [pscustomobject]@{ Tip = "Baslik"; Metin = (" " + $ik + " " + $g) }
        foreach ($m in ($MenuListesi | Where-Object { $_.Grup -eq $g })) {
            $satirlar += [pscustomobject]@{ Tip = "Oge"; No = $m.No; Ad = $m.Ad }
        }
    }
    return ,$satirlar
}

# ===================== ANA MENÃƒÅ“ (TEK DÃƒÅ“Z / FLAT) =====================
function Show-MainMenu {
    Clear-Host

    # ===== ÃƒÅ“ST BAÃ…ÂLIK BANDI =====
    Write-Host ("Ã¢â€¢â€" + ("Ã¢â€¢Â" * $BoxWidth) + "Ã¢â€¢â€”") -ForegroundColor $Tema.Cerceve

    # 1. ÃƒÅ“st BoÃ…Å¸luk (Nefes PayÃ„Â±)
    Write-Host "Ã¢â€¢â€˜" -ForegroundColor $Tema.Cerceve -NoNewline
    Write-Host (" " * $BoxWidth) -NoNewline
    Write-Host "Ã¢â€¢â€˜" -ForegroundColor $Tema.Cerceve

    # 2. Ana BaÃ…Å¸lÃ„Â±k
    $baslik = "Ã¢Å“Â¦  B Ã„Â° L G Ã„Â° S A Y A R   A R A C I  Ã¢Å“Â¦"
    $bPad = [math]::Max(1, [math]::Floor(($BoxWidth - $baslik.Length) / 2))
    Write-Host "Ã¢â€¢â€˜" -ForegroundColor $Tema.Cerceve -NoNewline
    Write-Host ((" " * $bPad) + $baslik + (" " * ($BoxWidth - $baslik.Length - $bPad))) -ForegroundColor $Tema.Vurgu -NoNewline
    Write-Host "Ã¢â€¢â€˜" -ForegroundColor $Tema.Cerceve

    # 3. Ã„Â°ÃƒÂ§ AyraÃƒÂ§ (BaÃ…Å¸lÃ„Â±k ile Slogan arasÃ„Â± ince ÃƒÂ§izgi)
    $ayracUzunluk = $BoxWidth - 6 
    $ayrac = "Ã¢â€â‚¬" * $ayracUzunluk
    $aPad = [math]::Floor(($BoxWidth - $ayracUzunluk) / 2)
    Write-Host "Ã¢â€¢â€˜" -ForegroundColor $Tema.Cerceve -NoNewline
    Write-Host ((" " * $aPad) + $ayrac + (" " * ($BoxWidth - $ayracUzunluk - $aPad))) -ForegroundColor $Tema.Soluk -NoNewline
    Write-Host "Ã¢â€¢â€˜" -ForegroundColor $Tema.Cerceve

    # 4. Slogan
    $slogan = "Kur Ã¢â‚¬Â¢ GÃƒÂ¼ncelle Ã¢â‚¬Â¢ Temizle Ã¢â‚¬Â¢ Yedekle Ã¢â‚¬Â¢ Onar"
    $sPad = [math]::Max(1, [math]::Floor(($BoxWidth - $slogan.Length) / 2))
    Write-Host "Ã¢â€¢â€˜" -ForegroundColor $Tema.Cerceve -NoNewline
    Write-Host ((" " * $sPad) + $slogan + (" " * ($BoxWidth - $slogan.Length - $sPad))) -ForegroundColor $Tema.Soluk -NoNewline
    Write-Host "Ã¢â€¢â€˜" -ForegroundColor $Tema.Cerceve

    # 5. Alt BoÃ…Å¸luk (Nefes PayÃ„Â±)
    Write-Host "Ã¢â€¢â€˜" -ForegroundColor $Tema.Cerceve -NoNewline
    Write-Host (" " * $BoxWidth) -NoNewline
    Write-Host "Ã¢â€¢â€˜" -ForegroundColor $Tema.Cerceve

    # ===== CANLI MÃ„Â°NÃ„Â° SÃ„Â°STEM DURUMU =====
    $durum = " Sistem durumu okunuyor..."
    try {
        $os = Get-CimInstance Win32_OperatingSystem -ErrorAction SilentlyContinue
        $cDisk = Get-CimInstance Win32_LogicalDisk -Filter "DeviceID='C:'" -ErrorAction SilentlyContinue
        
# Disk HesabÃ„Â±
        $cTop = [math]::Round($cDisk.Size / 1GB, 0)
        $cBos = [math]::Round($cDisk.FreeSpace / 1GB, 0)
        $cYuzde = if ($cTop -gt 0) { [math]::Round((($cTop - $cBos) / $cTop) * 100) } else { 0 }
        
        # RAM HesabÃ„Â± (Hem fiziksel hem sanal makine uyumlu)
        $ramTop = [math]::Round($os.TotalVisibleMemorySize / 1024 / 1024)
        $ramBos = [math]::Round($os.FreePhysicalMemory / 1024 / 1024, 1)
        # GÃƒÂ¼ncellenmiÃ…Å¸ Durum Ãƒâ€¡Ã„Â±ktÃ„Â±sÃ„Â±
        $durum = " ÄŸÅ¸â€™Â½ C: %$cYuzde dolu ($cBos GB boÃ…Å¸)   ÄŸÅ¸Â§Â  RAM: $ramBos GB boÃ…Å¸ / $ramTop GB"
    } catch {}

    Write-Host ("Ã¢â€¢Å¸" + ("Ã¢â€â‚¬" * $BoxWidth) + "Ã¢â€¢Â¢") -ForegroundColor $Tema.Cerceve
    
    $dPad = [math]::Max(1, $BoxWidth - $durum.Length)
    Write-Host "Ã¢â€¢â€˜" -ForegroundColor $Tema.Cerceve -NoNewline
    Write-Host ($durum + (" " * $dPad)).Substring(0, $BoxWidth) -ForegroundColor $Tema.Basari -NoNewline
    Write-Host "Ã¢â€¢â€˜" -ForegroundColor $Tema.Cerceve
    Write-Host ("Ã¢â€¢Å¸" + ("Ã¢â€â‚¬" * $BoxWidth) + "Ã¢â€¢Â¢") -ForegroundColor $Tema.Cerceve
    
    # ===== Ã„Â°KONLU GRUP DAÃ„ÂILIMI =====
    $ikon = @{
        "UYGULAMA" = "ÄŸÅ¸â€œÂ¦"; "BÃ„Â°LGÃ„Â°" = "Ã¢â€Â¹Ã¯Â¸Â "; "TEMÃ„Â°ZLÃ„Â°K" = "ÄŸÅ¸Â§Â¹"
        "BAKIM"    = "ÄŸÅ¸â€Â§"; "SÃƒÅ“RÃƒÅ“CÃƒÅ“" = "ÄŸÅ¸â€™Â¾"; "DÃ„Â°Ã„ÂER"    = "Ã¢Å¡â„¢Ã¯Â¸Â "
    }
    $solGruplar = @("UYGULAMA", "TEMÃ„Â°ZLÃ„Â°K", "SÃƒÅ“RÃƒÅ“CÃƒÅ“")
    $sagGruplar = @("BAKIM", "BÃ„Â°LGÃ„Â°", "DÃ„Â°Ã„ÂER")

    $solKolon = Get-Kolon -Gruplar $solGruplar -Ikon $ikon -MenuListesi $Menu
    $sagKolon = Get-Kolon -Gruplar $sagGruplar -Ikon $ikon -MenuListesi $Menu

    $satirSayisi = [math]::Max($solKolon.Count, $sagKolon.Count)
    $kolGenislik = [math]::Floor(($BoxWidth - 1) / 2)
    $sagGen = $BoxWidth - $kolGenislik - 1

    for ($i = 0; $i -lt $satirSayisi; $i++) {
        $solSatir = if ($i -lt $solKolon.Count) { $solKolon[$i] } else { $null }
        $sagSatir = if ($i -lt $sagKolon.Count) { $sagKolon[$i] } else { $null }

        Write-Host "Ã¢â€¢â€˜" -ForegroundColor $Tema.Cerceve -NoNewline

        # --- SOL HÃƒÅ“CRE ---
        if (-not $solSatir) {
            Write-Host (" " * $kolGenislik) -NoNewline
        } elseif ($solSatir.Tip -eq "Baslik") {
            $m = $solSatir.Metin
            if ($m.Length -gt $kolGenislik) { $m = $m.Substring(0, $kolGenislik) }
            Write-Host ($m + (" " * [math]::Max(0, $kolGenislik - $m.Length))) -ForegroundColor $Tema.Vurgu -NoNewline
        } else {
            $num = "  " + $solSatir.No.ToString().PadLeft(2) + ") "
            $ad = $solSatir.Ad
            if (($num + $ad).Length -gt $kolGenislik) { $ad = $ad.Substring(0, [math]::Max(0, $kolGenislik - $num.Length)) }
            $pad = [math]::Max(0, $kolGenislik - ($num.Length + $ad.Length))
            Write-Host $num -ForegroundColor $Tema.Vurgu -NoNewline
            Write-Host ($ad + (" " * $pad)) -ForegroundColor $Tema.Baslik -NoNewline
        }

        Write-Host "Ã¢â€â€š" -ForegroundColor $Tema.Cerceve -NoNewline

        # --- SAÃ„Â HÃƒÅ“CRE ---
        if (-not $sagSatir) {
            Write-Host (" " * $sagGen) -NoNewline
        } elseif ($sagSatir.Tip -eq "Baslik") {
            $m = $sagSatir.Metin
            if ($m.Length -gt $sagGen) { $m = $m.Substring(0, $sagGen) }
            Write-Host ($m + (" " * [math]::Max(0, $sagGen - $m.Length))) -ForegroundColor $Tema.Vurgu -NoNewline
        } else {
            $num = "  " + $sagSatir.No.ToString().PadLeft(2) + ") "
            $ad = $sagSatir.Ad
            if (($num + $ad).Length -gt $sagGen) { $ad = $ad.Substring(0, [math]::Max(0, $sagGen - $num.Length)) }
            $pad = [math]::Max(0, $sagGen - ($num.Length + $ad.Length))
            Write-Host $num -ForegroundColor $Tema.Vurgu -NoNewline
            Write-Host ($ad + (" " * $pad)) -ForegroundColor $Tema.Baslik -NoNewline
        }

        Write-Host "Ã¢â€¢â€˜" -ForegroundColor $Tema.Cerceve
    }

    # ===== ALT BANT =====
    Write-Host ("Ã¢â€¢Å¸" + ("Ã¢â€â‚¬" * $BoxWidth) + "Ã¢â€¢Â¢") -ForegroundColor $Tema.Cerceve

    $wtKurulu = $null -ne (Get-Command wt.exe -ErrorAction SilentlyContinue)
    if (-not $wtKurulu) {
        $wtPath = "$env:LOCALAPPDATA\Microsoft\WindowsApps\wt.exe"
        if (Test-Path $wtPath) { $wtKurulu = $true }
    }
    if (-not $wtKurulu) {
        $ipucu = "  ÄŸÅ¸â€™Â¡ Daha modern bir gÃƒÂ¶rÃƒÂ¼nÃƒÂ¼m iÃƒÂ§in Windows Terminal ÃƒÂ¶nerilir."
        $ipucu2 = "     Kurulum: MenÃƒÂ¼ 1 (Uygulama Kurulumu) Ã¢â€“Â¸ 15 numara."
        Show-Line $ipucu "Yellow"
        Show-Line $ipucu2 $Tema.Soluk
        Write-Host ("Ã¢â€¢Å¸" + ("Ã¢â€â‚¬" * $BoxWidth) + "Ã¢â€¢Â¢") -ForegroundColor $Tema.Cerceve
    }

    Show-Line "  Ã¢ÂÂ¤ Numara yazÃ„Â±p Enter'a basÃ„Â±n  Ã¢â‚¬Â¢  0) Ãƒâ€¡Ã„Â±kÃ„Â±Ã…Å¸" $Tema.Vurgu
    Show-Line "  Mehmet IÃ…ÂIK  Ã¢â‚¬Â¢  Bilgisayar AracÃ„Â±  Ã¢â‚¬Â¢  v2026" $Tema.Soluk
    Write-Host ("Ã¢â€¢Å¡" + ("Ã¢â€¢Â" * $BoxWidth) + "Ã¢â€¢Â") -ForegroundColor $Tema.Cerceve
    Write-Host ""
}

# ===================== ANA DÃƒâ€“NGÃƒÅ“ (TEK MENÃƒÅ“) =====================
$cikis = $false
do {
    try {
        Show-MainMenu
        $sec = Read-Host "  SeÃƒÂ§iminiz"

        if ($sec -eq "0") {
            $cikis = $true
        }
        elseif ($sec -match "^\d+$") {
            $secilen = $Menu | Where-Object { $_.No -eq [int]$sec }
            if ($secilen) {
                & $secilen.Eylem
            } else {
                Write-Host ""
                Write-Host "  GeÃƒÂ§ersiz numara: $sec" -ForegroundColor Red
                Start-Sleep -Milliseconds 900
            }
        }
        else {
            Write-Host ""
            Write-Host "  LÃƒÂ¼tfen geÃƒÂ§erli bir numara girin." -ForegroundColor Red
            Start-Sleep -Milliseconds 900
        }
    }
    catch {
        [Console]::CursorVisible = $true
        Write-Host ""
        Write-Host "  Ã„Â°Ã…ÂLEM SIRASINDA HATA OLUÃ…ÂTU:" -ForegroundColor Red
        Write-Host ("  " + $_.Exception.Message) -ForegroundColor Red
        Write-Host ""
        Read-Host "  Devam etmek iÃƒÂ§in Enter'a basÃ„Â±n"
    }
} while (-not $cikis)

Clear-Host
Write-Host "Program kapatÃ„Â±ldÃ„Â±. Ã„Â°yi gÃƒÂ¼nler, Mehmet IÃ…ÂIK!" -ForegroundColor Cyan

