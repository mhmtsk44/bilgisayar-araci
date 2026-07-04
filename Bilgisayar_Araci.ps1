<#
    Uygulama Ä°ndirme-GÃ¼ncelleme-SÃ¼rÃ¼cÃ¼ Yedek Alma-Temizleme AracÄ±
    HazÄ±rlayan: Mehmet IÅIK
    GÃ¼ncelleme: 04.07.2026
    KullanÄ±m: SaÄŸ tÄ±k -> "PowerShell ile Ã§alÄ±ÅŸtÄ±r" veya yÃ¶netici PowerShell'de:
              powershell -ExecutionPolicy RemoteSigned -File "Bilgisayar_Araci.ps1"
    NOT: DosyayÄ± "UTF-8 with BOM" olarak kaydedin (TÃ¼rkÃ§e + Ã§erÃ§eve karakterleri iÃ§in).
#>

# ===================== YÃ–NETÄ°CÄ° KONTROLÃœ + TEK PENCERE BAÅLATMA =====================

function Test-Admin {
    $kimlik = [Security.Principal.WindowsIdentity]::GetCurrent()
    $rol = New-Object Security.Principal.WindowsPrincipal($kimlik)
    return $rol.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

# ================================================================
#  WINGET KURULUM BETIGI - Nihai Surum v2 (Sahaya Ozel)
#  Iyilestirmeler: Hata loglama + Dinamik UI.Xaml + Ag Dalgalanma Korumasi + LTSC Guncelleme
# ================================================================

# AÄŸ baÄŸlantÄ±sÄ± sorunlarÄ±nÄ± Ã¶nlemek iÃ§in TLS 1.2'yi zorla (Eski sistemler iÃ§in kritik)
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
    param([string]$Soru = "Bu iÅŸlemi yapmak istediÄŸinize emin misiniz?")
    Write-Host ""
    $cevap = Read-Host "  $Soru (E/H)"
    return ($cevap -eq "E" -or $cevap -eq "e")
}

# ===================== LTSC / LTSB TESPÄ°TÄ° =====================
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

# ===================== ZAMAN AÅIMLI Ã‡ALIÅTIRMA YARDIMCISI =====================
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

# ===================== DOSYA Ä°NDÄ°RME YARDIMCISI (Yeniden Deneme KorumalÄ±) =====================
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

# ===================== NUGET SÃœRÃœM SORGUSU =====================
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

# ===================== UI.XAML TAMAMEN DÄ°NAMÄ°K Ã‡Ã–ZÃœM =====================
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

# ===================== GEÃ‡Ä°CÄ° DOSYA TEMÄ°ZLÄ°ÄÄ° =====================
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

# ===================== LTSC GÃœNCELLEME GÃ–REVÄ° =====================
function Kur-WingetLTSCGuncellemeGorevi {
    $GorevAdi = "Winget-OtomatikGuncelleme-LTSC"
    Write-Host "        LTSC otomatik gÃ¼ncelleme gÃ¶revi ayarlanÄ±yor..." -ForegroundColor DarkGray
    Yaz-Log "LTSC guncelleme gorevi olusturma baslatildi."

    try {
        Unregister-ScheduledTask -TaskName $GorevAdi -Confirm:$false -ErrorAction SilentlyContinue

        $tetikleyici = New-ScheduledTaskTrigger -Weekly -DaysOfWeek Friday -At 12:00pm
        $psKomut = "Install-PackageProvider -Name NuGet -Force -Scope CurrentUser -ErrorAction SilentlyContinue; Set-PSRepository -Name PSGallery -InstallationPolicy Trusted -ErrorAction SilentlyContinue; Install-Script -Name winget-install -Force -Scope CurrentUser -ErrorAction SilentlyContinue; `$p = (Get-InstalledScript winget-install).InstalledLocation; & (Join-Path `$p 'winget-install.ps1') -Force"
        
        $eylem = New-ScheduledTaskAction -Execute "powershell.exe" -Argument "-WindowStyle Hidden -NonInteractive -NoProfile -Command `"$psKomut`""

        Register-ScheduledTask -TaskName $GorevAdi -Trigger $tetikleyici -Action $eylem -Description "LTSC sistemlerde Winget'i guncel tutmak icin haftalik kontrol yapar." -ErrorAction Stop | Out-Null
        
        Yaz-Log "LTSC guncelleme gorevi basariyla kaydedildi."
    } catch {
        Write-Host "        GÃ¼ncelleme gÃ¶revi oluÅŸturulamadÄ±!" -ForegroundColor Red
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

# ===================== WINGET KURULUM ANA FONKSÄ°YONU =====================
function Install-Winget {
    param([switch]$Sessiz)
    
    if (-not $Sessiz) { Write-Host "Winget durumu kontrol ediliyor..." -ForegroundColor Cyan }
    if (Get-Command winget -ErrorAction SilentlyContinue) {
        if (-not $Sessiz) { Write-Host "Winget bu sistemde zaten kurulu!" -ForegroundColor Green }
        Yaz-Log "Winget zaten kurulu."
        
        # Zaten kuruluysa LTSC ise yine de gÃ¶rev atayalÄ±m (Ã¶nceden kurulmuÅŸ ama gÃ¶rev atÄ±lmamÄ±ÅŸ olabilir)
        if (Test-LTSC) { Kur-WingetLTSCGuncellemeGorevi }
        return $true
    }
Write-Host ""
    Write-Host "  Sistemde Winget (Windows Paket YÃ¶neticisi) bulunamadÄ±." -ForegroundColor Yellow
    Write-Host "  Uygulama indirme ve gÃ¼ncelleme menÃ¼lerinin Ã§alÄ±ÅŸmasÄ± iÃ§in gereklidir." -ForegroundColor DarkGray
    if (-not (Confirm-Islem "Winget ÅŸimdi kurulsun mu?")) {
        Write-Host "  Winget kurulumu atlandÄ±. Winget gerektiren menÃ¼ler Ã§alÄ±ÅŸmayacaktÄ±r." -ForegroundColor Red
        Yaz-Log "Winget kurulumu kullanÄ±cÄ± tarafÄ±ndan iptal edildi." 'UYARI'
        Start-Sleep -Seconds 2
        return $false
    }
    Write-Host "Sistem mimarisi inceleniyor..." -ForegroundColor Cyan
    $ltsc = Test-LTSC

    if ($ltsc) {
        Write-Host "SÄ°STEM TESPÄ°TÄ°: LTSC / LTSB SÃ¼rÃ¼mÃ¼!" -ForegroundColor Yellow
        Write-Host "Ã–zel LTSC yÃ¶ntemi (PSGallery) baÅŸlatÄ±lÄ±yor..." -ForegroundColor DarkGray

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
                # --- GÃœNCELLEME GÃ–REVÄ° BURADA Ã‡AÄRILIYOR ---
                Kur-WingetLTSCGuncellemeGorevi
            }
        } catch {
            Write-Host "LTSC kurulumu sirasinda hata." -ForegroundColor Red
            Yaz-Log "LTSC kurulum istisnasi: $($_.Exception.Message)" 'HATA'
        }

    } else {
        Write-Host "SÄ°STEM TESPÄ°TÄ°: Standart Windows SÃ¼rÃ¼mÃ¼." -ForegroundColor Green
        Write-Host "Normal kurulum (App Installer) baÅŸlatÄ±lÄ±yor..." -ForegroundColor DarkGray
        
        # Indir-Dosya kullanÄ±larak standart indirme daha gÃ¼venli hale getirildi
        $getwinget = Join-Path $env:TEMP "getwinget.msixbundle"
        if (Indir-Dosya "https://aka.ms/getwinget" $getwinget 120) {
            try { Add-AppxPackage -Path $getwinget -ErrorAction Stop; Yaz-Log "Standart paket kuruldu." }
            catch { Yaz-Log "Standart kurulum hatasi: $($_.Exception.Message)" 'HATA' }
        }
    }

    Start-Sleep -Seconds 3
    if (Get-Command winget -ErrorAction SilentlyContinue) {
        Write-Host "Ä°ÅŸlem TamamlandÄ±: Winget baÅŸarÄ±yla kuruldu (birincil yol)!" -ForegroundColor Green
        Temizle-GeciciDosyalar
        return $true
    }

    Write-Host "Birincil yol sonuc vermedi -> manuel yedek yola geciliyor..." -ForegroundColor DarkYellow
    Install-WingetManuel

    Start-Sleep -Seconds 3
    Temizle-GeciciDosyalar

    if (Get-Command winget -ErrorAction SilentlyContinue) {
        Write-Host "Ä°ÅŸlem TamamlandÄ±: Winget baÅŸarÄ±yla kuruldu (manuel yedek yol)!" -ForegroundColor Green
        if ($ltsc) { Kur-WingetLTSCGuncellemeGorevi } # Manuel yolla kurulduysa ve LTSC ise gÃ¶rev ata
        return $true
    } else {
        Write-Host "Ä°ÅŸlem BaÅŸarÄ±sÄ±z: Winget kurulamadÄ±. Log: $Global:LogDosyasi" -ForegroundColor Red
        return $false
    }
}

# BetiÄŸin indirileceÄŸi adres (yalnÄ±zca yerel dosya yoksa yedek olarak kullanÄ±lÄ±r)
$ScriptUrl = "https://raw.githubusercontent.com/mhmtsk44/bilgisayar-araci/refs/heads/main/Bilgisayar_Araci.ps1"

# Ã‡alÄ±ÅŸan betiÄŸin tam yolu (yÃ¶netici/terminal yÃ¼kseltmesinde AYNI dosya yeniden Ã§alÄ±ÅŸÄ±r)
$BetikYolu = $PSCommandPath
if ([string]::IsNullOrWhiteSpace($BetikYolu)) { $BetikYolu = $MyInvocation.MyCommand.Path }

# YÃ¼kseltme komutunu Ã¼ret: yerel dosya varsa onu Ã§alÄ±ÅŸtÄ±r, yoksa indir
function Get-BaslatmaKomutu {
    if (-not [string]::IsNullOrWhiteSpace($BetikYolu) -and (Test-Path $BetikYolu)) {
        # GÃœVENLÄ°: incelenen yerel dosyanÄ±n kendisi Ã§alÄ±ÅŸÄ±r, offline da Ã§alÄ±ÅŸÄ±r
        return @{ Tip = "Dosya"; Deger = $BetikYolu }
    } else {
        # YEDEK: yerel dosya yoksa (Ã¶rn. irm ile Ã§aÄŸrÄ±ldÄ±ysa) uzaktan indir
        return @{ Tip = "Komut"; Deger = "irm '$ScriptUrl' | iex" }
    }
}

# AÅAMA 1: YÃ¶netici deÄŸilsek -> yÃ¶netici olarak yeniden baÅŸlat
if (-not (Test-Admin)) {
    Write-Host "YÃ¶netici izniyle yeniden baÅŸlatÄ±lÄ±yor..." -ForegroundColor Yellow
    $bk = Get-BaslatmaKomutu
    try {
        if ($bk.Tip -eq "Dosya") {
            Start-Process powershell -ArgumentList "-ExecutionPolicy Bypass -File `"$($bk.Deger)`"" -Verb RunAs -ErrorAction Stop
        } else {
            # UZAKTAN (irm|iex) MOD: -NoExit eklendi ki hata olsa da pencere kapanmasÄ±n
            Start-Process powershell -ArgumentList "-NoExit -ExecutionPolicy Bypass -Command `"$($bk.Deger)`"" -Verb RunAs -ErrorAction Stop
        }
    } catch {
        Write-Host ""
        Write-Host "HATA: YÃ¶netici izni verilmedi veya yÃ¼kseltme baÅŸarÄ±sÄ±z oldu." -ForegroundColor Red
        Write-Host "AyrÄ±ntÄ±: $($_.Exception.Message)" -ForegroundColor DarkYellow
        Write-Host ""
        Read-Host "Kapatmak iÃ§in Enter'a basÄ±n"
    }
    exit
}

# AÅAMA 1.5: Winget'i garantiye al (-Sessiz parametresiyle, ekranda yazÄ± kalabalÄ±ÄŸÄ± yapmaz)
$WingetVar = Install-Winget -Sessiz

# ===================== AÅAMA 2: WINDOWS TERMINAL'DE AÃ‡ (gÃ¼venli, dÃ¶ngÃ¼sÃ¼z) =====================
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
                # DÃ¶ngÃ¼ bayraÄŸÄ±nÄ± Ã–NCEDEN bu pencerede ayarla; yeni pencere miras alÄ±r
                [Environment]::SetEnvironmentVariable("BILGISAYAR_ARACI_WT", "1", "Process")
                # -File ile Ã§alÄ±ÅŸtÄ±r: yol boÅŸluk iÃ§erse bile gÃ¼venli
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
            exit   # wt aÃ§Ä±ldÄ± -> baÅŸlatÄ±cÄ± pencereyi kapat
        } catch {
            # wt aÃ§Ä±lamadÄ± -> bu pencerede devam et
        }
    }
}

# ===================== TEMEL AYARLAR =====================
$ErrorActionPreference = "Continue"
$Host.UI.RawUI.WindowTitle = "Bilgisayar AracÄ± - Mehmet IÅIK"
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

# ===================== MODERN TEMA / RENK PALETÄ° =====================
$Tema = @{
    Cerceve  = "DarkCyan"
    Vurgu    = "Cyan"
    Metin    = "Gray"
    Baslik   = "White"
    Basari   = "Green"
    Hata     = "Red"
    Soluk    = "DarkGray"
}
# ===================== MODERN Ã‡ERÃ‡EVE =====================
$BoxWidth = 78
function Show-Top    { Write-Host ("â•”" + ("â•" * $BoxWidth) + "â•—") -ForegroundColor $Tema.Cerceve }
function Show-Bottom { Write-Host ("â•š" + ("â•" * $BoxWidth) + "â•") -ForegroundColor $Tema.Cerceve }
function Show-Divider{ Write-Host ("â•Ÿ" + ("â”€" * $BoxWidth) + "â•¢") -ForegroundColor $Tema.Cerceve }
function Show-Line {
    param([string]$Metin, [string]$Renk = $Tema.Metin)
    
    # âœ¨ emojisi 1 karakter gÃ¶rÃ¼nÃ¼r ama ekranda 2 birim yer kaplar. 
    # HesabÄ± dÃ¼zeltmek iÃ§in 'âœ¨' yerine geÃ§ici olarak iki nokta '..' saydÄ±rÄ±yoruz.
    $sanalUzunluk = ($Metin -replace 'âœ¨', '..').Length

    $temiz = $Metin
    if ($sanalUzunluk -gt $BoxWidth) { $temiz = $temiz.Substring(0, $BoxWidth) }
    $bosluk = [math]::Max(1, $BoxWidth - $sanalUzunluk)
    
    Write-Host "â•‘" -ForegroundColor $Tema.Cerceve -NoNewline
    Write-Host (" " + $temiz + (" " * ($bosluk - 1))) -ForegroundColor $Renk -NoNewline
    Write-Host "â•‘" -ForegroundColor $Tema.Cerceve
}

function Show-Header {
    param([string]$Baslik)
    Clear-Host
    Show-Top
    Show-Line "  ğŸ’» BÄ°LGÄ°SAYAR YÃ–NETÄ°M ARACI" $Tema.Soluk
    Show-Line "  â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€" $Tema.Soluk  # Ä°nce bir ayraÃ§
    Show-Line "  âœ¨ $Baslik" $Tema.Vurgu
    Show-Bottom
    Write-Host ""
}

function Write-Result {
    param(
        $Basari,
        $Mesaj = ""
    )

    # --- AKILLI PARAMETRE ALGILAMA (iki Ã§aÄŸrÄ± stilini de destekler) ---
    #   DOÄRU:  Write-Result $true "mesaj"      (bool, string)
    #   ESKÄ°:   Write-Result $true "mesaj"       (string, bool)  â† otomatik dÃ¼zeltilir
    # EÄŸer $Basari bool DEÄÄ°L ama $Mesaj bool ise, parametreler ters gelmiÅŸtir â†’ yer deÄŸiÅŸtir.
    if (($Basari -isnot [bool]) -and ($Mesaj -is [bool])) {
        $gecici = $Basari
        $Basari = $Mesaj
        $Mesaj  = $gecici
    }

    # --- Basari deÄŸerini gÃ¼venli ÅŸekilde Boolean'a Ã§evir ---
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

    # $Mesaj'Ä± her zaman metne Ã§evir (bool geldiyse bile gÃ¼venli)
    $mesajMetni = "$Mesaj"

    if ($durum) {
        Write-Host "  âœ“  $mesajMetni" -ForegroundColor $Tema.Basari
    } else {
        Write-Host "  âœ—  $mesajMetni" -ForegroundColor $Tema.Hata
    }
}

# ===================== WINGET BÄ°LGÄ°LENDÄ°RME EKRANI =====================
function Show-WingetHelp {
    Show-Header "WINGET (PAKET YÃ–NETÄ°CÄ°SÄ°) BULUNAMADI"

    Write-Host "  BilgisayarÄ±nÄ±zda Winget yÃ¼klÃ¼ deÄŸil." -ForegroundColor $Tema.Hata
    Write-Host ""
    Write-Host "  Winget, Windows 10 (1809+) ve Windows 11'de varsayÄ±lan" -ForegroundColor $Tema.Metin
    Write-Host "  olarak gelen resmi bir paket yÃ¶neticisidir. YÃ¼klÃ¼ deÄŸilse" -ForegroundColor $Tema.Metin
    Write-Host "  aÅŸaÄŸÄ±daki yÃ¶ntemlerden biriyle kurabilirsiniz." -ForegroundColor $Tema.Metin
    Write-Host ("  " + ("-" * 74)) -ForegroundColor $Tema.Cerceve

    Write-Host "  YÃ–NTEM 1 â€” Microsoft Store (Ã–nerilen)" -ForegroundColor $Tema.Vurgu
    Write-Host "   1) BaÅŸlat menÃ¼sÃ¼nden 'Microsoft Store' uygulamasÄ±nÄ± aÃ§Ä±n." -ForegroundColor $Tema.Metin
    Write-Host "   2) Arama Ã§ubuÄŸuna 'Uygulama YÃ¼kleyici' yazÄ±n." -ForegroundColor $Tema.Metin
    Write-Host "      (Ä°ngilizce: 'App Installer')" -ForegroundColor $Tema.Soluk
    Write-Host "   3) 'Uygulama YÃ¼kleyici'yi bulun ve YÃ¼kle/GÃ¼ncelle deyin." -ForegroundColor $Tema.Metin
    Write-Host "   4) Kurulum bitince winget kullanÄ±ma hazÄ±r olur." -ForegroundColor $Tema.Metin
    Write-Host ""

    Write-Host "  YÃ–NTEM 2 â€” GeliÅŸtirici Modu Ã¼zerinden" -ForegroundColor $Tema.Vurgu
    Write-Host "   1) BaÅŸlat > 'Ayarlar' uygulamasÄ±nÄ± aÃ§Ä±n." -ForegroundColor $Tema.Metin
    Write-Host "   2) 'Gizlilik ve GÃ¼venlik' > 'GeliÅŸtiriciler iÃ§in' bÃ¶lÃ¼mÃ¼ne gidin." -ForegroundColor $Tema.Metin
    Write-Host "      (Win 10: 'GÃ¼ncelleme ve GÃ¼venlik' > 'GeliÅŸtiriciler iÃ§in')" -ForegroundColor $Tema.Soluk
    Write-Host "   3) 'GeliÅŸtirici Modu'nu aÃ§Ä±n." -ForegroundColor $Tema.Metin
    Write-Host "   4) ArdÄ±ndan Store'dan 'Uygulama YÃ¼kleyici'yi kurun." -ForegroundColor $Tema.Metin
    Write-Host ""

    Write-Host "  YÃ–NTEM 3 â€” Otomatik kurulum (bu araÃ§)" -ForegroundColor $Tema.Vurgu
    Write-Host "   Bu araÃ§ aÃ§Ä±lÄ±ÅŸta winget'i otomatik kurmayÄ± dener." -ForegroundColor $Tema.Metin
    Write-Host "   BaÅŸarÄ±sÄ±z olduysa internet baÄŸlantÄ±nÄ±zÄ± kontrol edip" -ForegroundColor $Tema.Metin
    Write-Host "   programÄ± yeniden baÅŸlatÄ±n." -ForegroundColor $Tema.Metin
    Write-Host ""

    # KullanÄ±cÄ±yÄ± doÄŸrudan Store'a yÃ¶nlendirme seÃ§eneÄŸi
    $ac = Read-Host "  Microsoft Store'da 'Uygulama YÃ¼kleyici' sayfasÄ±nÄ± aÃ§mak ister misiniz? (E/H)"
    if ($ac -eq "E" -or $ac -eq "e") {
        try {
            Start-Process "ms-windows-store://pdp/?productid=9NBLGGH4NNS1" -ErrorAction Stop
            Write-Result $true "Microsoft Store aÃ§Ä±ldÄ± (Uygulama YÃ¼kleyici sayfasÄ±)."
        } catch {
            try {
                Start-Process "ms-windows-store://search/?query=Uygulama YÃ¼kleyici" -ErrorAction Stop
                Write-Result $true "Microsoft Store arama sayfasÄ± aÃ§Ä±ldÄ±."
            } catch {
                Write-Result $false "Microsoft Store aÃ§Ä±lamadÄ±: $($_.Exception.Message)"
            }
        }
    } else {
        Write-Result $true "Store aÃ§Ä±lmadÄ±. Winget'i daha sonra kurabilirsiniz."
    }

    Write-Host ""
    Read-Host "  Devam etmek iÃ§in Enter'a basÄ±n"
}

# ===================== WINGET KAYNAK GÃœNCELLEME =====================
if ($WingetVar) {
    winget source update 2>$null | Out-Null
    if ($LASTEXITCODE -ne 0) {
        Write-Host "Uyari: winget kaynak guncellemesi tamamlanamadi." -ForegroundColor DarkYellow
    }
}

# ===================== YARDIMCI FONKSÄ°YONLAR =====================
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
    param([string]$Aciklama = "KlasÃ¶r seÃ§in")
    Add-Type -AssemblyName System.Windows.Forms
    $dlg = New-Object System.Windows.Forms.FolderBrowserDialog
    $dlg.Description = $Aciklama
    if ($dlg.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) { return $dlg.SelectedPath }
    return $null
}

function Select-File {
    param([string]$Filtre = "JSON DosyasÄ± (*.json)|*.json|TÃ¼m Dosyalar (*.*)|*.*")
    Add-Type -AssemblyName System.Windows.Forms
    $dlg = New-Object System.Windows.Forms.OpenFileDialog
    $dlg.Filter = $Filtre
    if ($dlg.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) { return $dlg.FileName }
    return $null
}
# ===================== UYGULAMA LÄ°STESÄ° (dizi â€” sÄ±ra %100 korunur) =====================

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
    @{ No = 16; Ad = "Alpemix (Uzak BaÄŸlantÄ±)";   Id = "ALPEMIX_OZEL" }
)

# ===================== UYGULAMA KURULUM =====================

function Install-App {
    param([string]$Ad, [string]$Id, [string]$Kaynak = "winget")

    if ($Id -eq "ALPEMIX_OZEL") {
        Install-Alpemix
        return
    }

    # winget yoksa erken Ã§Ä±k
    if (-not $WingetVar) {
        Write-Result $false "$Ad kurulamadÄ±: winget bulunamadÄ±."
        return
    }

    Write-Host "  $Ad kuruluyor..." -ForegroundColor Yellow

    # Store uygulamalarÄ± iÃ§in msstore kaynaÄŸÄ±, diÄŸerleri iÃ§in varsayÄ±lan winget kaynaÄŸÄ±
    if ($Kaynak -eq "msstore") {
        $argumanlar = "install --id $Id --source msstore --accept-package-agreements --accept-source-agreements"
    } else {
        $argumanlar = "install --id $Id --silent --accept-package-agreements --accept-source-agreements"
    }

    $sonuc = Start-Process winget -ArgumentList $argumanlar -Wait -PassThru -NoNewWindow
    switch ($sonuc.ExitCode) {
        0           { Write-Result $true "$Ad baÅŸarÄ±yla kuruldu." }
        -1978335189 { Write-Result $true "$Ad zaten gÃ¼ncel / yÃ¼klÃ¼." }
        default     { Write-Result $false "$Ad kurulamadÄ± (Kod: $($sonuc.ExitCode))." }
    }
}

# ===================== ALPEMIX Ã–ZEL Ä°NDÄ°RME (Ä°MZA KONTROLLÃœ) =====================
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
            Write-Result $false "Ä°ndirilen dosya bozuk gÃ¶rÃ¼nÃ¼yor ($boyutKB KB). Ä°ptal edildi."
            Remove-Item $hedef -Force -ErrorAction SilentlyContinue
            return
        }
        Write-Result $true "Alpemix indirildi: $hedef ($boyutKB KB)"

        $imza = Get-AuthenticodeSignature $hedef
        $imzaGuvenli = $false
        switch ($imza.Status) {
            "Valid" {
                $imzaci = $imza.SignerCertificate.Subject
                Write-Result $true "Dijital imza GEÃ‡ERLÄ°."
                Write-Host ("       Ä°mzalayan: " + $imzaci) -ForegroundColor DarkGray
                $imzaGuvenli = $true
            }
            "NotSigned" {
                Write-Result $false "UYARI: Dosya dijital olarak Ä°MZALANMAMIÅ."
            }
            default {
                Write-Result $false ("UYARI: Ä°mza durumu gÃ¼vensiz: " + $imza.Status)
            }
        }

        if (-not $imzaGuvenli) {
            Write-Host ""
            Write-Host "  Bu dosyanÄ±n imzasÄ± doÄŸrulanamadÄ±. YalnÄ±zca kaynaÄŸa" -ForegroundColor Yellow
            Write-Host "  gÃ¼veniyorsanÄ±z Ã§alÄ±ÅŸtÄ±rÄ±n." -ForegroundColor Yellow
        }
        $ac = Read-Host "  Alpemix ÅŸimdi Ã§alÄ±ÅŸtÄ±rÄ±lsÄ±n mÄ±? (E/H)"
        if ($ac -eq "E" -or $ac -eq "e") {
            Start-Process $hedef
            Write-Result $true "Alpemix baÅŸlatÄ±ldÄ±."
        } else {
            Write-Result $true "Ã‡alÄ±ÅŸtÄ±rma iptal edildi. Dosya masaÃ¼stÃ¼nde duruyor."
        }
    } catch {
        Write-Result $false "Alpemix indirilemedi: $($_.Exception.Message)"
    }
}

# ===================== TÃœM UYGULAMALARI GÃœNCELLE =====================
function Update-AllApps {
    Show-Header "TÃœM UYGULAMALARI GÃœNCELLE"

    # Winget yoksa yardÄ±m ekranÄ±nÄ± gÃ¶ster (Kod 2'den)
    if (-not $WingetVar) {
        Show-WingetHelp
        return
    }

    Write-Host "  Sistemde yÃ¼klÃ¼ tÃ¼m programlar gÃ¼ncelleniyor..." -ForegroundColor "Yellow"
    Write-Host "  (winget upgrade --all)" -ForegroundColor $Tema.Soluk
    Write-Host ""

    if (-not (Confirm-Islem "TÃ¼m uygulamalar gÃ¼ncellensin mi?")) {
        Write-Result $false "Ä°ÅŸlem iptal edildi."
        Read-Host "  Devam etmek iÃ§in Enter'a basÄ±n"
        return
    }

    Write-Host ""
    Write-Host "  GÃ¼ncelleme baÅŸlatÄ±lÄ±yor, lÃ¼tfen bekleyin..." -ForegroundColor $Tema.Vurgu
    Write-Host "  (Bu iÅŸlem birkaÃ§ dakika sÃ¼rebilir.)" -ForegroundColor $Tema.Soluk
    Write-Host ""

    try {
        # KRÄ°TÄ°K: --disable-interactivity + --silent (Kod 1'den) â†’ takÄ±lma/Ã§ift onay engellenir
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

    # ===== Ã–ZET KUTUSU (Kod 2'den) =====
    Write-Host ""
    Show-Top
    Show-Line "  GÃœNCELLEME Ã–ZETÄ°" $Tema.Baslik
    Show-Divider
    if ($kod -eq 0 -or $null -eq $kod) {
        Show-Line "  âœ“ GÃ¼ncelleme iÅŸlemi tamamlandÄ±." $Tema.Basari
    } else {
        Show-Line "  âš  BazÄ± paketler gÃ¼ncellenemedi (Ã§Ä±kÄ±ÅŸ kodu: $kod)." $Tema.Hata
    }
    Show-Line "  Not: GÃ¼ncellenecek paket yoksa 'her ÅŸey gÃ¼ncel' demektir." $Tema.Soluk
    Show-Bottom

    Write-Host ""
    Read-Host "  Devam etmek iÃ§in Enter'a basÄ±n"
}
# ===================== SÄ°STEM FONKSÄ°YONLARI =====================

function New-AdminFolders {
    Show-Header "YÃ–NETÄ°M KLASÃ–RLERÄ° OLUÅTUR"
    Write-Host ""
    $onay = Read-Host "  MasaÃ¼stÃ¼nde Admin ve GodMode klasÃ¶rleri oluÅŸturulsun mu? (E/H)"
    if ($onay -ne "E" -and $onay -ne "e") {
        Write-Result $false "Ä°ÅŸlem iptal edildi."; Write-Host ""; Read-Host "  Devam etmek iÃ§in Enter'a basÄ±n"; return
    }
    $masaustu = [Environment]::GetFolderPath("Desktop")
    try {
        $adminYol   = Join-Path $masaustu "YÃ¶netim AraÃ§larÄ±.{D20EA4E1-3957-11d2-A40B-0C5020524153}"
        $godmodeYol = Join-Path $masaustu "GodMode.{ED7BA470-8E54-465E-825C-99712043E01C}"
        if (-not (Test-Path $adminYol))   { New-Item -Path $adminYol -ItemType Directory -Force | Out-Null }
        if (-not (Test-Path $godmodeYol)) { New-Item -Path $godmodeYol -ItemType Directory -Force | Out-Null }
        Write-Result $true "YÃ¶netim ve GodMode klasÃ¶rleri masaÃ¼stÃ¼nde oluÅŸturuldu."
    } catch {
        Write-Result $false "KlasÃ¶r oluÅŸturulamadÄ±: $($_.Exception.Message)"
    }
    Write-Host ""
    Read-Host "  Devam etmek iÃ§in Enter'a basÄ±n"
}

function Show-SystemInfo {
    Show-Header "SÄ°STEM BÄ°LGÄ°LERÄ°"
    try {
        $os  = Get-CimInstance Win32_OperatingSystem
        $cs  = Get-CimInstance Win32_ComputerSystem
        $cpu = Get-CimInstance Win32_Processor | Select-Object -First 1
        
        # DOÄRU RAM HESABI (Hem fiziksel hem sanal makine uyumlu)
        $ram = [math]::Round($os.TotalVisibleMemorySize / 1024 / 1024)

        Write-Host ("  Bilgisayar : " + $cs.Name)          -ForegroundColor $Tema.Baslik
        Write-Host ("  Ä°ÅŸletim S. : " + $os.Caption)       -ForegroundColor $Tema.Baslik
        Write-Host ("  SÃ¼rÃ¼m      : " + $os.Version)        -ForegroundColor $Tema.Metin
        Write-Host ("  Ä°ÅŸlemci    : " + $cpu.Name.Trim())   -ForegroundColor $Tema.Metin
        Write-Host ("  RAM        : " + $ram + " GB")        -ForegroundColor $Tema.Metin
        Write-Host ("  Ãœretici    : " + $cs.Manufacturer)   -ForegroundColor $Tema.Metin
    } catch {
        Write-Host ("  Bilgi alÄ±namadÄ±: " + $_.Exception.Message) -ForegroundColor $Tema.Hata
    }
    Write-Host ""
    Read-Host "  Devam etmek iÃ§in Enter'a basÄ±n"
}
function Show-DiskSummary {
    Show-Header "DÄ°SK Ã–ZETÄ°"
    try {
        Get-CimInstance Win32_LogicalDisk -Filter "DriveType=3" | ForEach-Object {
            $toplam = [math]::Round($_.Size / 1GB, 1)
            $bos    = [math]::Round($_.FreeSpace / 1GB, 1)
            $dolu   = $toplam - $bos
            $yuzde  = if ($toplam -gt 0) { [math]::Round(($dolu / $toplam) * 100) } else { 0 }
            Write-Host ("  SÃ¼rÃ¼cÃ¼ " + $_.DeviceID + "  Toplam: $toplam GB  BoÅŸ: $bos GB  (%$yuzde dolu)") -ForegroundColor $Tema.Baslik
        }
    } catch {
        Write-Host ("  Disk bilgisi alÄ±namadÄ±.") -ForegroundColor $Tema.Hata
    }
    Write-Host ""
    Read-Host "  Devam etmek iÃ§in Enter'a basÄ±n"
}

function Show-DiskHealth {
    Show-Header "DÄ°SK SAÄLIÄI (SMART)"
    try {
        Get-PhysicalDisk | ForEach-Object {
            $durum = $_.HealthStatus
            $renk = if ($durum -eq "Healthy") { $Tema.Basari } else { $Tema.Hata }
            Write-Host ("  " + $_.FriendlyName + "  Durum: " + $durum) -ForegroundColor $renk
        }
    } catch {
        Write-Host ("  Disk saÄŸlÄ±k bilgisi alÄ±namadÄ±.") -ForegroundColor $Tema.Hata
    }
    Write-Host ""
    Read-Host "  Devam etmek iÃ§in Enter'a basÄ±n"
}
function Show-Startup {
    Show-Header "BAÅLANGIÃ‡ PROGRAMLARI"

    # --- KayÄ±tlÄ± baÅŸlangÄ±Ã§ programlarÄ±nÄ± listele + say ---
    $sayac = 0
    try {
        Get-CimInstance Win32_StartupCommand | ForEach-Object {
            $sayac++
            Write-Host ("  " + $_.Name + "  ->  " + $_.Command) -ForegroundColor $Tema.Metin
        }
        if ($sayac -eq 0) {
            Write-Host "  KayÄ±tlÄ± baÅŸlangÄ±Ã§ programÄ± bulunamadÄ±." -ForegroundColor $Tema.Soluk
        } else {
            Write-Host ("  " + ("-" * 50)) -ForegroundColor $Tema.Cerceve
            Write-Host ("  Toplam $sayac baÅŸlangÄ±Ã§ programÄ± bulundu.") -ForegroundColor $Tema.Vurgu
        }
    } catch {
        Write-Host "  BaÅŸlangÄ±Ã§ programlarÄ± alÄ±namadÄ±." -ForegroundColor $Tema.Hata
    }

    Write-Host ""

    # --- E/H sorusu: BaÅŸlangÄ±Ã§ ayar ekranÄ±nÄ± aÃ§mak ister mi? ---
    Write-Host "  Windows BaÅŸlangÄ±Ã§ ayarlarÄ±nÄ± aÃ§mak ister misiniz? " -NoNewline -ForegroundColor $Tema.Metin
    Write-Host "(E/H)" -ForegroundColor $Tema.Vurgu
    $cevap = Read-Host "  SeÃ§iminiz"

    if ($cevap -match '^[EeYy]') {
        Write-Host ""
        Write-Host "  Windows BaÅŸlangÄ±Ã§ ayarlarÄ± aÃ§Ä±lÄ±yor..." -ForegroundColor $Tema.Metin
        try {
            Start-Process "ms-settings:startupapps" -ErrorAction Stop
            Write-Result $true "Ayarlar > BaÅŸlangÄ±Ã§ sayfasÄ± aÃ§Ä±ldÄ±."
        } catch {
            try {
                Start-Process "taskmgr.exe" -ArgumentList "/0 /startup" -ErrorAction Stop
                Write-Result $true "GÃ¶rev YÃ¶neticisi (BaÅŸlangÄ±Ã§ sekmesi) aÃ§Ä±ldÄ±."
            } catch {
                Write-Result $false "BaÅŸlangÄ±Ã§ ayarlarÄ± aÃ§Ä±lamadÄ±: $($_.Exception.Message)"
            }
        }
    } else {
        Write-Host ""
        Write-Result $true "BaÅŸlangÄ±Ã§ ayarlarÄ± aÃ§Ä±lmadÄ±. Ana menÃ¼ye dÃ¶nÃ¼lÃ¼yor."
    }

    Read-Host "`n  Devam etmek iÃ§in Enter'a basÄ±n"
}

function Start-WindowsUpdate {
    Show-Header "WINDOWS GÃœNCELLEMELERÄ°"
    Write-Host ""
    $onay = Read-Host "  Windows gÃ¼ncellemeleri aranÄ±p kurulsun mu? (E/H)"
    if ($onay -ne "E" -and $onay -ne "e") {
        Write-Result $false "Ä°ÅŸlem iptal edildi."; Write-Host ""; Read-Host "  Devam etmek iÃ§in Enter'a basÄ±n"; return
    }
    try {
        if (-not (Get-Module -ListAvailable -Name PSWindowsUpdate)) {
            Write-Progress -Activity "Windows Update" -Status "PSWindowsUpdate modÃ¼lÃ¼ kuruluyor..." -PercentComplete 10
            Write-Host "  [1/3] PSWindowsUpdate modÃ¼lÃ¼ kuruluyor..." -ForegroundColor Yellow
            Install-PackageProvider -Name NuGet -Force -ErrorAction SilentlyContinue | Out-Null
            Install-Module PSWindowsUpdate -Force -Scope CurrentUser -Confirm:$false -ErrorAction SilentlyContinue
        } else {
            Write-Host "  [1/3] PSWindowsUpdate modÃ¼lÃ¼ hazÄ±r." -ForegroundColor DarkGray
        }

        Write-Progress -Activity "Windows Update" -Status "ModÃ¼l yÃ¼kleniyor..." -PercentComplete 40
        Import-Module PSWindowsUpdate -ErrorAction SilentlyContinue

        Write-Progress -Activity "Windows Update" -Status "GÃ¼ncellemeler aranÄ±yor ve kuruluyor..." -PercentComplete 70
        Write-Host "  [2/3] GÃ¼ncellemeler aranÄ±yor..." -ForegroundColor Yellow
        Write-Host "  [3/3] Bulunanlar kuruluyor (bu iÅŸlem uzun sÃ¼rebilir)..." -ForegroundColor Yellow
        Write-Host ""

        # -Verbose ile her gÃ¼ncellemenin durumu ekrana yansÄ±r
        Get-WindowsUpdate -AcceptAll -Install -IgnoreReboot -Verbose

        Write-Progress -Activity "Windows Update" -Completed
        Write-Host ""
        Write-Result $true "Windows gÃ¼ncelleme iÅŸlemi tamamlandÄ±."
    } catch {
        Write-Progress -Activity "Windows Update" -Completed
        Write-Result $false "GÃ¼ncelleme yapÄ±lamadÄ±: $($_.Exception.Message)"
    }
    Write-Host ""
    Read-Host "  Devam etmek iÃ§in Enter'a basÄ±n"
}

function Reset-Network {
    Show-Header "AÄ SIFIRLAMA"
    Write-Host ""
if (-not (Confirm-Islem "AÄŸ ayarlarÄ± sÄ±fÄ±rlanacak (DNS, Winsock, IP). Emin misiniz?")) {
    Write-Result $false "Ä°ÅŸlem iptal edildi."
    Write-Host ""; Read-Host "  Devam etmek iÃ§in Enter'a basÄ±n"; return
}

    try {
        ipconfig /flushdns | Out-Null
        netsh winsock reset | Out-Null
        netsh int ip reset | Out-Null
        Write-Result $true "AÄŸ ayarlarÄ± sÄ±fÄ±rlandÄ±. BilgisayarÄ± yeniden baÅŸlatÄ±n."
    } catch {
        Write-Result $false "AÄŸ sÄ±fÄ±rlanamadÄ±: $($_.Exception.Message)"
    }
    Write-Host ""
    Read-Host "  Devam etmek iÃ§in Enter'a basÄ±n"
}

function New-RestorePoint {
    Show-Header "SÄ°STEM GERÄ° YÃœKLEME NOKTASI"
    Write-Host ""
    $onay = Read-Host "  Sistem geri yÃ¼kleme noktasÄ± oluÅŸturulsun mu? (E/H)"
    if ($onay -ne "E" -and $onay -ne "e") {
        Write-Result $false "Ä°ÅŸlem iptal edildi."; Write-Host ""; Read-Host "  Devam etmek iÃ§in Enter'a basÄ±n"; return
    }

try {
        Enable-ComputerRestore -Drive "C:\" -ErrorAction SilentlyContinue
        Checkpoint-Computer -Description "Bilgisayar Araci - $(Get-Date -Format 'yyyy-MM-dd HH:mm')" -RestorePointType "MODIFY_SETTINGS" -ErrorAction Stop
        Write-Result $true "Geri yÃ¼kleme noktasÄ± oluÅŸturuldu."
    } catch {
        Write-Result $false "Geri yÃ¼kleme noktasÄ± oluÅŸturulamadÄ±: $($_.Exception.Message)"
    }

    Write-Host ""
    Read-Host "  Devam etmek iÃ§in Enter'a basÄ±n"
}

function Clear-PrintQueue {
    Show-Header "YAZICI KUYRUÄUNU TEMÄ°ZLE"
    Write-Host ""
    $onay = Read-Host "  YazÄ±cÄ± kuyruÄŸu temizlenecek. OnaylÄ±yor musunuz? (E/H)"
    if ($onay -ne "E" -and $onay -ne "e") {
        Write-Result $false "Ä°ÅŸlem iptal edildi."; Write-Host ""; Read-Host "  Devam etmek iÃ§in Enter'a basÄ±n"; return
    }
    try {
        Stop-Service -Name Spooler -Force -ErrorAction SilentlyContinue
        Remove-Item "$env:SystemRoot\System32\spool\PRINTERS\*" -Force -ErrorAction SilentlyContinue
        Start-Service -Name Spooler -ErrorAction SilentlyContinue
        Write-Result $true "YazÄ±cÄ± kuyruÄŸu temizlendi."
    } catch {
        Write-Result $false "YazÄ±cÄ± kuyruÄŸu temizlenemedi: $($_.Exception.Message)"
    }
    Write-Host ""
    Read-Host "  Devam etmek iÃ§in Enter'a basÄ±n"
}

function Show-HealthSummary {
    Show-Header "SÄ°STEM SAÄLIK Ã–ZETÄ°"
    try {
        $os  = Get-CimInstance Win32_OperatingSystem
        $cs  = Get-CimInstance Win32_ComputerSystem
        
        # DOÄRU RAM HESABI
        $ram = [math]::Round($os.TotalVisibleMemorySize / 1024 / 1024)
        $bosRam = [math]::Round($os.FreePhysicalMemory / 1024 / 1024, 1)
        
        $cDisk = Get-CimInstance Win32_LogicalDisk -Filter "DeviceID='C:'"
        $cBos = [math]::Round($cDisk.FreeSpace / 1GB, 1)
        $cTop = [math]::Round($cDisk.Size / 1GB, 1)
        $uptime = (Get-Date) - $os.LastBootUpTime

        Write-Host ("  RAM        : " + $ram + " GB  (BoÅŸ: " + $bosRam + " GB)") -ForegroundColor $Tema.Baslik
        Write-Host ("  C: Disk    : " + $cTop + " GB  (BoÅŸ: " + $cBos + " GB)") -ForegroundColor $Tema.Baslik
        Write-Host ("  Ã‡alÄ±ÅŸma S. : " + $uptime.Days + " gÃ¼n " + $uptime.Hours + " saat") -ForegroundColor $Tema.Metin

        $cYuzde = if ($cTop -gt 0) { [math]::Round((($cTop - $cBos) / $cTop) * 100) } else { 0 }
        Write-Host ("  " + ("-" * 50)) -ForegroundColor $Tema.Cerceve
        if ($cYuzde -gt 90) { Write-Host "  âš  C: sÃ¼rÃ¼cÃ¼sÃ¼ neredeyse dolu!" -ForegroundColor $Tema.Hata }
        elseif ($cYuzde -gt 75) { Write-Host "  âš  C: sÃ¼rÃ¼cÃ¼sÃ¼nde yer azalÄ±yor." -ForegroundColor Yellow }
        else { Write-Host "  âœ“ Disk durumu iyi." -ForegroundColor $Tema.Basari }

        if ($bosRam -lt 1) { Write-Host "  âš  BoÅŸ RAM dÃ¼ÅŸÃ¼k!" -ForegroundColor $Tema.Hata }
        else { Write-Host "  âœ“ RAM durumu iyi." -ForegroundColor $Tema.Basari }
    } catch {
        Write-Host ("  SaÄŸlÄ±k Ã¶zeti alÄ±namadÄ±: " + $_.Exception.Message) -ForegroundColor $Tema.Hata
    }
    Write-Host ""
    Read-Host "  Devam etmek iÃ§in Enter'a basÄ±n"
}

# ===================== GÃœVENLÄ°K: TEHLÄ°KELÄ° YOL KONTROLÃœ (SON HAL v2) =====================
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
# ===================== TEMÄ°ZLÄ°K FONKSÄ°YONLARI =====================
function Clean-Temp {
    Show-Header "GEÃ‡Ä°CÄ° DOSYALARI TEMÄ°ZLE"

    $hedefler = @(
        @{ Ad = "KullanÄ±cÄ± TEMP";        Yol = $env:TEMP }
        @{ Ad = "Windows TEMP";          Yol = "$env:SystemRoot\Temp" }
        @{ Ad = "Yerel AppData TEMP";    Yol = "$env:LOCALAPPDATA\Temp" }
        @{ Ad = "Prefetch";              Yol = "$env:SystemRoot\Prefetch" }
        @{ Ad = "Thumbnail Ã–nbellek";    Yol = "$env:LOCALAPPDATA\Microsoft\Windows\Explorer" }
        @{ Ad = "Son KullanÄ±lanlar";     Yol = "$env:APPDATA\Microsoft\Windows\Recent" }
    )

    if (-not (Confirm-Islem "GeÃ§ici dosyalar temizlensin mi?")) {
        Write-Result $false "Ä°ÅŸlem iptal edildi."
        Read-Host "  Devam etmek iÃ§in Enter'a basÄ±n"
        return
    }

    Write-Host ""
    $toplamKazanc = 0.0
    $toplamSilinen = 0
    $toplamHata    = 0

    foreach ($k in $hedefler) {
        if ([string]::IsNullOrWhiteSpace($k.Yol) -or -not (Test-Path $k.Yol)) {
            Write-Host ("  â–¸ " + $k.Ad + " â€” bulunamadÄ±, atlandÄ±.") -ForegroundColor $Tema.Soluk
            continue
        }

        if (-not (Test-GuvenliYol $k.Yol)) {
            Write-Host ("  âš  " + $k.Ad + " â€” GÃœVENLÄ°K nedeniyle atlandÄ±.") -ForegroundColor Yellow
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
        Write-Host ("  âœ“ " + $k.Ad.PadRight(22) + " temizlendi â€” $hedefSilinen dosya, $hedefKazancYuvarli MB") -ForegroundColor $Tema.Basari

        $toplamKazanc  += $hedefKazanc
        $toplamSilinen += $hedefSilinen
        $toplamHata    += $hedefHata
    }

    $kazancYuvarli = [math]::Round($toplamKazanc, 2)

    # ===== Ã–ZET KUTUSU =====
    Write-Host ""
    Show-Top
    Show-Line "  TEMÄ°ZLÄ°K Ã–ZETÄ°" $Tema.Baslik
    Show-Divider
    Show-Line ("  Silinen dosya    : " + $toplamSilinen) $Tema.Metin
    Show-Line ("  KazanÄ±lan alan   : " + $kazancYuvarli + " MB") $Tema.Basari
    if ($toplamHata -gt 0) {
        Show-Line ("  Atlanan (kilitli): " + $toplamHata + " dosya (normal)") $Tema.Soluk
    }
    Show-Bottom

    Write-Host ""
    Write-Host "  Not: Prefetch silindiÄŸi iÃ§in ilk aÃ§Ä±lÄ±ÅŸlar biraz yavaÅŸ" -ForegroundColor $Tema.Soluk
    Write-Host "  olabilir, sistem birkaÃ§ aÃ§Ä±lÄ±ÅŸta yeniden oluÅŸturur." -ForegroundColor $Tema.Soluk

    Write-Host ""
    Read-Host "  Devam etmek iÃ§in Enter'a basÄ±n"
}
function Clean-Logs {
    Show-Header "OLAY GÃœNLÃœKLERÄ°NÄ° TEMÄ°ZLE"

    Write-Host "  Windows olay gÃ¼nlÃ¼kleri temizleniyor..." -ForegroundColor "Yellow"
    Write-Host "  (Bu iÅŸlem birkaÃ§ dakika sÃ¼rebilir, lÃ¼tfen bekleyin)" -ForegroundColor $Tema.Soluk
    Write-Host ""

    if (-not (Confirm-Islem "TÃ¼m olay gÃ¼nlÃ¼kleri temizlensin mi?")) {
        Write-Result $false "Ä°ÅŸlem iptal edildi."
        Read-Host "  Devam etmek iÃ§in Enter'a basÄ±n"
        return
    }

    Write-Host ""

    try {
        $loglar = @(wevtutil el 2>$null)
        $toplam = $loglar.Count

        if ($toplam -eq 0) {
            Write-Result $false "Temizlenecek olay gÃ¼nlÃ¼ÄŸÃ¼ bulunamadÄ±."
            Write-Host ""
            Read-Host "  Devam etmek iÃ§in Enter'a basÄ±n"
            return
        }

        $sayac    = 0
        $basarili = 0
        $zamanAsimi = 0

        foreach ($log in $loglar) {
            $sayac++

            $yuzde = [math]::Round(($sayac / $toplam) * 100)
            $dolu  = [math]::Round($yuzde / 100 * 30)
            $cubuk = ("â–ˆ" * $dolu) + ("â–‘" * (30 - $dolu))
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
        Write-Host ("`r  [" + ("â–ˆ" * 30) + "]  %100  tamamlandÄ±            ") -ForegroundColor Green
        Write-Host ""

        Write-Result $true "$basarili / $toplam olay gÃ¼nlÃ¼ÄŸÃ¼ temizlendi."
        if ($zamanAsimi -gt 0) {
            Write-Host "  Not: $zamanAsimi gÃ¼nlÃ¼k zaman aÅŸÄ±mÄ±na uÄŸradÄ±ÄŸÄ± iÃ§in atlandÄ±." -ForegroundColor $Tema.Soluk
        }
        if ($basarili -lt $toplam) {
            Write-Host "  Not: BazÄ± korumalÄ± gÃ¼nlÃ¼kler temizlenemez (normaldir)." -ForegroundColor $Tema.Soluk
        }
    } catch {
        Write-Result $false ("GÃ¼nlÃ¼kler temizlenirken hata: " + $_.Exception.Message)
    }

    Write-Host ""
    Read-Host "  Devam etmek iÃ§in Enter'a basÄ±n"
}
function Clean-WinUpdate {
    Show-Header "WINDOWS UPDATE Ã–NBELLEÄÄ°NÄ° TEMÄ°ZLE"
    try {
        Stop-Service -Name wuauserv -Force -ErrorAction SilentlyContinue
        Remove-Item "$env:SystemRoot\SoftwareDistribution\Download\*" -Recurse -Force -ErrorAction SilentlyContinue
        Start-Service -Name wuauserv -ErrorAction SilentlyContinue
        Write-Result $true "Windows Update Ã¶nbelleÄŸi temizlendi."
    } catch {
        Write-Result $false "Ã–nbellek temizlenemedi: $($_.Exception.Message)"
    }
    Write-Host ""
    Read-Host "  Devam etmek iÃ§in Enter'a basÄ±n"
}

function Clean-RecycleBin {
    Show-Header "GERÄ° DÃ–NÃœÅÃœM KUTUSU TEMÄ°ZLE"
    Write-Host ""

    try {
        Clear-RecycleBin -Force -ErrorAction Stop
        Write-Host "  âœ“  Geri dÃ¶nÃ¼ÅŸÃ¼m kutusu temizlendi" -ForegroundColor $Tema.Basari
    }
    catch {
        if ($_.Exception.Message -match "belirtilen yolu bulamÄ±yor" -or
            $_.Exception.Message -match "cannot find the path" -or
            $_.Exception.Message -match "Recycle Bin.*empty" -or
            $_.Exception.Message -match "boÅŸ") {
            Write-Host "  âœ“  Geri dÃ¶nÃ¼ÅŸÃ¼m kutusu temizlendi" -ForegroundColor $Tema.Basari
        }
        else {
            Write-Host "  âœ—  Geri dÃ¶nÃ¼ÅŸÃ¼m kutusu boÅŸaltÄ±lamadÄ±: $($_.Exception.Message)" -ForegroundColor $Tema.Hata
        }
    }

    Write-Host ""
    Read-Host "  Devam etmek iÃ§in Enter'a basÄ±n"
}
function Clean-Disk {
    Show-Header "DÄ°SK TEMÄ°ZLEME ARACI (cleanmgr)"
    try {
        Start-Process cleanmgr -ArgumentList "/sagerun:1" -Wait
        Write-Result $true "Disk Temizleme aracÄ± Ã§alÄ±ÅŸtÄ±rÄ±ldÄ±."
    } catch {
        Write-Result $false "Disk Temizleme Ã§alÄ±ÅŸtÄ±rÄ±lamadÄ±: $($_.Exception.Message)"
    }
    Write-Host ""
    Read-Host "  Devam etmek iÃ§in Enter'a basÄ±n"
}
function Clean-GpuLeftovers {
    Show-Header "EKRAN KARTI SÃœRÃœCÃœ ARTIKLARINI TEMÄ°ZLE"

    Write-Host "  Bu iÅŸlem AMD / NVIDIA / Intel kurulum artÄ±klarÄ±nÄ± temizler." -ForegroundColor $Tema.Metin
    Write-Host "  (YÃ¼klÃ¼ sÃ¼rÃ¼cÃ¼ler etkilenmez, yalnÄ±zca kurulum klasÃ¶rleri)" -ForegroundColor $Tema.Soluk
    Write-Host ""

    if (-not (Confirm-Islem "SÃ¼rÃ¼cÃ¼ kurulum artÄ±klarÄ± temizlensin mi?")) {
        Write-Result $false "Ä°ÅŸlem iptal edildi."
        Read-Host "  Devam etmek iÃ§in Enter'a basÄ±n"
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
            Write-Result $true ((Split-Path $h -Leaf) + " klasÃ¶rÃ¼ yok, atlandÄ±.")
            continue
        }

        $tam = (Resolve-Path $h -ErrorAction SilentlyContinue).Path
        if ($tam -and ($yasakli -contains $tam.TrimEnd('\'))) {
            Write-Result $false ("GÃœVENLÄ°K nedeniyle atlandÄ±: " + $tam)
            continue
        }

        $ad = Split-Path $h -Leaf
        $oncesi = Get-FolderSizeMB $h
        try {
            Remove-Item -Path $h -Recurse -Force -ErrorAction SilentlyContinue
            $kazanc += $oncesi
            Write-Result $true ($ad + " kurulum artÄ±klarÄ± temizlendi.")
        } catch {
            Write-Result $false ($ad + " temizlenirken hata: " + $_.Exception.Message)
        }
    }

    Write-Host ""
    Write-Host ("  " + ("-" * 50)) -ForegroundColor $Tema.Cerceve
    Write-Result $true ("Toplam temizlenen alan: $kazanc MB")

    Write-Host ""
    Read-Host "  Devam etmek iÃ§in Enter'a basÄ±n"
}
# ==================================================================================
#  HÄ°BRÄ°T PROTECT-USB  (v3.2)
# ==================================================================================
function Protect-USB {
    Show-Header "USB DÄ°SK KORUMA / BÄ°Ã‡Ä°MLENDÄ°RME (HÄ°BRÄ°T v3.2)"

    $diskler = Get-Disk | Where-Object { $_.BusType -eq 'USB' }
    if (-not $diskler) {
        Write-Host "  BaÄŸlÄ± USB disk bulunamadÄ±." -ForegroundColor $Tema.Hata
        Write-Host ""
        Read-Host "  Devam etmek iÃ§in Enter'a basÄ±n"
        return
    }

    Write-Host "  BaÄŸlÄ± USB diskler:" -ForegroundColor $Tema.Vurgu
    Write-Host ""
    foreach ($d in $diskler) {
        $boyutGB = [math]::Round($d.Size / 1GB, 1)
        Write-Host ("   Disk {0}  |  {1}  |  {2} GB" -f $d.Number, $d.FriendlyName, $boyutGB) -ForegroundColor $Tema.Metin
    }
    Write-Host ""

    $secim = Read-Host "  Ä°ÅŸlem yapÄ±lacak disk numarasÄ±nÄ± girin (iptal iÃ§in q)"
    if ($secim -eq 'q' -or [string]::IsNullOrWhiteSpace($secim)) {
        Write-Result $false "Ä°ÅŸlem iptal edildi."
        Read-Host "  Devam etmek iÃ§in Enter'a basÄ±n"
        return
    }

    $diskNo = 0
    if (-not [int]::TryParse($secim, [ref]$diskNo)) {
        Write-Result $false "GeÃ§ersiz disk numarasÄ±."
        Read-Host "  Devam etmek iÃ§in Enter'a basÄ±n"
        return
    }

    $hedefDisk = $diskler | Where-Object { $_.Number -eq $diskNo }
    if (-not $hedefDisk) {
        Write-Result $false "Belirtilen numarada USB disk bulunamadÄ±."
        Read-Host "  Devam etmek iÃ§in Enter'a basÄ±n"
        return
    }

    if ($hedefDisk.BusType -ne 'USB') {
        Write-Host "  âš  UYARI: Bu disk USB deÄŸil! Ä°ÅŸlem gÃ¼venlik nedeniyle durduruldu." -ForegroundColor $Tema.Hata
        Write-Host ""
        Read-Host "  Devam etmek iÃ§in Enter'a basÄ±n"
        return
    }

    $diskBoyutGB = [math]::Round($hedefDisk.Size / 1GB, 1)
    if ($diskBoyutGB -gt 512) {
        Write-Host "  âš  UYARI: Disk Ã§ok bÃ¼yÃ¼k ($diskBoyutGB GB). Harici HDD olabilir." -ForegroundColor $Tema.Hata
        if (-not (Confirm-Islem "Yine de devam edilsin mi?")) {
            Write-Result $false "Ä°ÅŸlem iptal edildi."
            Read-Host "  Devam etmek iÃ§in Enter'a basÄ±n"
            return
        }
    }

    Write-Host ""
    Write-Host ("  SeÃ§ilen: Disk {0} - {1} ({2} GB)" -f $hedefDisk.Number, $hedefDisk.FriendlyName, $diskBoyutGB) -ForegroundColor $Tema.Vurgu
    Write-Host ""
    Write-Host "  Ne yapmak istersiniz?" -ForegroundColor $Tema.Baslik
    Write-Host "   1) GÃœVENLÄ° HALE GETÄ°R + biÃ§imlendir (TÃœM VERÄ° SÄ°LÄ°NÄ°R, autorun korumasÄ± eklenir)" -ForegroundColor $Tema.Metin
    Write-Host "   2) BÃ¶lÃ¼mleri listele (salt okuma, gÃ¼venli)" -ForegroundColor $Tema.Metin
    Write-Host "   q) Ä°ptal" -ForegroundColor $Tema.Soluk
    Write-Host ""

    $islemTipi = Read-Host "  SeÃ§iminiz"

    switch ($islemTipi) {
        "1" {
            Write-Host ""
            Write-Host ("  " + ("â•" * 50)) -ForegroundColor $Tema.Hata
            Write-Host "  âš  KALICI VERÄ° SÄ°LME + KORUMA Ä°ÅLEMÄ°" -ForegroundColor $Tema.Hata
            Write-Host ("   Disk   : {0}" -f $hedefDisk.FriendlyName) -ForegroundColor $Tema.Metin
            Write-Host ("   Boyut  : {0} GB" -f $diskBoyutGB) -ForegroundColor $Tema.Metin
            Write-Host "   Silinecek: Diskteki TÃœM bÃ¶lÃ¼mler ve veriler" -ForegroundColor $Tema.Metin
            Write-Host ("  " + ("â•" * 50)) -ForegroundColor $Tema.Hata
            Write-Host ""

            $onay = Read-Host "  Onaylamak iÃ§in diskin adÄ±nÄ± yazÄ±n ('$($hedefDisk.FriendlyName)')"
            if ($onay -ne $hedefDisk.FriendlyName) {
                Write-Result $false "Disk adÄ± eÅŸleÅŸmedi. Ä°ÅŸlem gÃ¼venlik nedeniyle iptal edildi."
                Read-Host "  Devam etmek iÃ§in Enter'a basÄ±n"
                return
            }

            try {
                Write-Host ""
                Write-Host "  Ä°ÅŸlem yapÄ±lÄ±yor, lÃ¼tfen bekleyin..." -ForegroundColor $Tema.Vurgu

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
                    Write-Result $false "SÃ¼rÃ¼cÃ¼ harfi atanamadÄ±. Diski Ã§Ä±karÄ±p yeniden takmayÄ± deneyin veya manuel harf atayÄ±n."
                    Read-Host "  Devam etmek iÃ§in Enter'a basÄ±n"
                    return
                }

                Format-Volume -Partition $yeniBolum -FileSystem NTFS -NewFileSystemLabel $eskiEtiket -Confirm:$false -ErrorAction Stop | Out-Null
                $harf = $yeniBolum.DriveLetter + ":"

                $guvenliKlasor = "$harf\GÃ¼venliDosya"
                New-Item -Path $guvenliKlasor -ItemType Directory -Force | Out-Null

                $autorunYolu = "$harf\autorun.inf"
                try {
                    New-Item -Path $autorunYolu -ItemType Directory -Force -ErrorAction Stop | Out-Null
                    attrib +h +s $autorunYolu                                                  
                    icacls $autorunYolu /deny "*S-1-1-0:(OI)(CI)(F)" /Q | Out-Null   
                } catch {
                    Write-Host ("  âš  Autorun korumasÄ± uygulanamadÄ±: " + $_.Exception.Message) -ForegroundColor $Tema.Hata
                }

                icacls "$harf\" /deny "*S-1-1-0:(AD,WD)" /Q | Out-Null
                icacls $guvenliKlasor /grant "*S-1-1-0:(OI)(CI)(F)" /Q | Out-Null

                Write-Host ""
                Write-Result $true ("Ä°ÅŸlem tamamlandÄ±! SÃ¼rÃ¼cÃ¼: " + $harf + "  |  Etiket: " + $eskiEtiket)
                Write-Host "  MÃ¼kemmel! Ana dizine doÄŸrudan virÃ¼s/dosya atÄ±lamaz, ama sÃ¼rÃ¼cÃ¼ normal aÃ§Ä±lÄ±r." -ForegroundColor $Tema.Basari
                Write-Host ("  TÃ¼m dosyalarÄ±nÄ±zÄ± '{0}\GÃ¼venliDosya' iÃ§ine atmalÄ±sÄ±nÄ±z." -f $harf) -ForegroundColor $Tema.Basari
            } catch {
                Write-Result $false ("Ä°ÅŸlem baÅŸarÄ±sÄ±z: " + $_.Exception.Message)
            }

            Write-Host ""
            Read-Host "  Devam etmek iÃ§in Enter'a basÄ±n"
        }

        "2" {
            Write-Host ""
            Write-Host "  Disk Ã¼zerindeki bÃ¶lÃ¼mler:" -ForegroundColor $Tema.Vurgu
            Write-Host ""
            try {
                $bolumler = Get-Partition -DiskNumber $diskNo -ErrorAction Stop
                foreach ($b in $bolumler) {
                    $bBoyutGB = [math]::Round($b.Size / 1GB, 2)
                    $harf = if ($b.DriveLetter) { $b.DriveLetter + ":" } else { "(harf yok)" }
                    Write-Host ("   BÃ¶lÃ¼m {0}  |  {1}  |  {2} GB" -f $b.PartitionNumber, $harf, $bBoyutGB) -ForegroundColor $Tema.Metin
                }
            } catch {
                Write-Result $false ("BÃ¶lÃ¼mler listelenemedi: " + $_.Exception.Message)
            }

            Write-Host ""
            Read-Host "  Devam etmek iÃ§in Enter'a basÄ±n"
        }

        default {
            Write-Result $false "Ä°ÅŸlem iptal edildi."
            Read-Host "  Devam etmek iÃ§in Enter'a basÄ±n"
        }
    }
}
# ===================== DÄ°SK KONTROL VE ONARIM (chkdsk) =====================
function Repair-Disk {
    Show-Header "SÄ°STEM VE DÄ°SK ONARIMI"

    Write-Host "  YapÄ±lacak iÅŸlemi seÃ§in:" -ForegroundColor $Tema.Metin
    Write-Host ""
    Write-Host "   [1] Sistem dosyasÄ± onarÄ±mÄ± (SFC /scannow)" -ForegroundColor $Tema.Metin
    Write-Host "   [2] Sistem gÃ¶rÃ¼ntÃ¼sÃ¼ onarÄ±mÄ± (DISM RestoreHealth)" -ForegroundColor $Tema.Metin
    Write-Host "   [3] Disk kontrolÃ¼ (CHKDSK - disk seÃ§meli)" -ForegroundColor $Tema.Metin
    Write-Host "   [4] Tam Sistem OnarÄ±mÄ± (DISM + SFC Birlikte)" -ForegroundColor $Tema.Vurgu
    Write-Host "   [0] Geri" -ForegroundColor $Tema.Soluk
    Write-Host ""

    $girdi = Read-Host "  SeÃ§iminiz"

    [int]$anaSecim = 0
    if (-not [int]::TryParse($girdi, [ref]$anaSecim)) {
        Write-Result $false "GeÃ§ersiz giriÅŸ. LÃ¼tfen bir sayÄ± girin."
        Read-Host "  Devam etmek iÃ§in Enter'a basÄ±n"
        return
    }

    switch ($anaSecim) {
        0 { return }

        1 {
            Write-Host ""
            Write-Host "  SFC taramasÄ± baÅŸlatÄ±lÄ±yor..." -ForegroundColor $Tema.Metin
            sfc /scannow
            Write-Host ""
            Read-Host "  Devam etmek iÃ§in Enter'a basÄ±n"
        }

        2 {
            Write-Host ""
            Write-Host "  DISM onarÄ±mÄ± baÅŸlatÄ±lÄ±yor..." -ForegroundColor $Tema.Metin
            DISM /Online /Cleanup-Image /RestoreHealth
            Write-Host ""
            Read-Host "  Devam etmek iÃ§in Enter'a basÄ±n"
        }

        4 {
            Write-Host ""
            Write-Host "  SFC + DISM sÄ±rayla Ã§alÄ±ÅŸtÄ±rÄ±lÄ±yor..." -ForegroundColor $Tema.Metin
            sfc /scannow
            DISM /Online /Cleanup-Image /RestoreHealth
            Write-Host ""
            Read-Host "  Devam etmek iÃ§in Enter'a basÄ±n"
        }

        3 {
            Invoke-ChkdskSecmeli
        }

        default {
            Write-Result $false "GeÃ§ersiz seÃ§im: $anaSecim"
            Read-Host "  Devam etmek iÃ§in Enter'a basÄ±n"
        }
    }
}
function Invoke-ChkdskSecmeli {
    Show-Header "DÄ°SK KONTROLÃœ (CHKDSK)"

    try {
        $diskler = Get-Disk | Sort-Object Number -ErrorAction Stop
    } catch {
        Write-Result $false "Disk bilgisi alÄ±namadÄ±: $($_.Exception.Message)"
        Write-Host ""; Read-Host "  Devam etmek iÃ§in Enter'a basÄ±n"; return
    }

    if (-not $diskler) {
        Write-Result $false "HiÃ§ disk bulunamadÄ±."
        Write-Host ""; Read-Host "  Devam etmek iÃ§in Enter'a basÄ±n"; return
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
            $sistemMi = if ($disk.IsBoot -or $disk.IsSystem) { ' [SÄ°STEM DÄ°SKÄ°]' } else { '' }

            Write-Host ("  [Disk $($disk.Number)] $model") -ForegroundColor $Tema.Baslik
            Write-Host ("     $busType - $boyutGB GB$sistemMi") -ForegroundColor $Tema.Soluk

            $bolumler = Get-Partition -DiskNumber $disk.Number -ErrorAction SilentlyContinue |
                        Where-Object { $_.DriveLetter }

            if (-not $bolumler) {
                Write-Host "        (harflendirilmiÅŸ bÃ¶lÃ¼m yok)" -ForegroundColor $Tema.Soluk
                Write-Host ""
                continue
            }

            foreach ($bolum in $bolumler) {
                $harf     = $bolum.DriveLetter
                $vol      = Get-Volume -DriveLetter $harf -ErrorAction SilentlyContinue
                $etiket   = if ($vol.FileSystemLabel) { $vol.FileSystemLabel } else { 'etiket yok' }
                $fs       = if ($vol.FileSystem) { $vol.FileSystem } else { '?' }
                $bolBoyut = if ($vol.Size) { [math]::Round($vol.Size / 1GB, 2) } else { 0 }
                $sysMi    = if ($harf -eq $env:SystemDrive.TrimEnd(':')) { ' [SÄ°STEM]' } else { '' }

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
            Write-Result $false "Taranabilecek harflendirilmiÅŸ bÃ¶lÃ¼m yok."
            Write-Host ""; Read-Host "  Devam etmek iÃ§in Enter'a basÄ±n"; return
        }

        $girdiSecim = Read-Host "  Taramak istediÄŸin bÃ¶lÃ¼m numarasÄ± (Ä°ptal iÃ§in 0)"

        [int]$secim = 0
        if (-not [int]::TryParse($girdiSecim, [ref]$secim)) {
            Write-Result $false "GeÃ§ersiz giriÅŸ. SayÄ± girmelisiniz. Tekrar deneyin."
            continue   
        }
        if ($secim -eq 0) {
            Write-Result $false "Ä°ÅŸlem iptal edildi."
            Write-Host ""; Read-Host "  Devam etmek iÃ§in Enter'a basÄ±n"; return
        }

        $aday = $harfListesi | Where-Object { $_.No -eq $secim }
        if (-not $aday) {
            Write-Result $false "GeÃ§ersiz seÃ§im ($secim). Listeden bir numara seÃ§in."
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
        Write-Host "  â–¸ SeÃ§ilen: $secimAdi" -ForegroundColor $Tema.Vurgu
        Write-Host ""

        $dogruMu = Read-Host "  Bu bÃ¶lÃ¼m doÄŸru mu? (E = evet devam / H = hayÄ±r tekrar seÃ§)"
        if ($dogruMu.ToUpper() -ne 'E') {
            Write-Host "  Tekrar seÃ§im yapabilirsiniz..." -ForegroundColor $Tema.Soluk
            continue   
        }

        $secilen = $aday   
    }

    $harf = $secilen.Harf
    $fs   = $secilen.FS

    if ($fs -in @('exFAT', 'FAT', 'FAT32')) {
        Write-Host ""
        Write-Host "  UYARI: $secimAdi" -ForegroundColor Yellow
        Write-Host "  $fs formatÄ±nda chkdsk sÄ±nÄ±rlÄ± Ã§alÄ±ÅŸÄ±r (/R yok)." -ForegroundColor $Tema.Soluk
        Write-Host ""
    }

    Write-Host "  Tarama modu seÃ§:" -ForegroundColor $Tema.Baslik
    Write-Host "     1) HÄ±zlÄ±  (/F /X) - hatalarÄ± dÃ¼zelt" -ForegroundColor $Tema.Metin
    Write-Host "     2) Derin  (/R /X) - bozuk sektÃ¶r (Ã§ok uzun)" -ForegroundColor $Tema.Metin
    Write-Host ""
    $modGirdi = Read-Host "  Mod (1/2)"

    if ($fs -in @('exFAT', 'FAT', 'FAT32') -and $modGirdi -eq '2') {
        Write-Result $false "$fs formatÄ±nda /R yok. HÄ±zlÄ± moda geÃ§iliyor."
        $modGirdi = '1'
    }

    $parametre = if ($modGirdi -eq '2') { '/R /X' } else { '/F /X' }

    if ($secilen.Sistem) {
        Write-Host ""
        Write-Host "  $secimAdi" -ForegroundColor $Tema.Vurgu
        Write-Host "  Bu bir SÄ°STEM sÃ¼rÃ¼cÃ¼sÃ¼. Åimdi taranamaz." -ForegroundColor Yellow
        Write-Host "  Yeniden baÅŸlatmada taranacak ÅŸekilde planlanabilir." -ForegroundColor $Tema.Metin
        Write-Host ""
        $ok = Read-Host "  PlanlansÄ±n mÄ±? (E/H)"
        if ($ok.ToUpper() -eq 'E') {
            cmd /c "echo Y| chkdsk $harf`: $parametre" | Out-Null
            Write-Result $true "$secimAdi â†’ yeniden baÅŸlatmada taranacak."
        } else {
            Write-Result $false "Ä°ÅŸlem iptal edildi."
        }
        Write-Host ""; Read-Host "  Devam etmek iÃ§in Enter'a basÄ±n"; return
    }

    Write-Host ""
    Write-Host "  â–º Taranacak: $secimAdi" -ForegroundColor $Tema.Baslik
    Write-Host "  â–º Mod: $parametre" -ForegroundColor $Tema.Baslik
    Write-Host "  /X sÃ¼rÃ¼cÃ¼ baÄŸlantÄ±sÄ±nÄ± geÃ§ici keser." -ForegroundColor $Tema.Soluk
    Write-Host "  AÃ§Ä±k dosyalar kapanacak. Devam edilsin mi?" -ForegroundColor $Tema.Metin
    Write-Host ""
    $ok = Read-Host "  Devam? (E/H)"
    if ($ok.ToUpper() -ne 'E') {
        Write-Result $false "Ä°ÅŸlem iptal edildi."
        Write-Host ""; Read-Host "  Devam etmek iÃ§in Enter'a basÄ±n"; return
    }

    Write-Host ""
    Write-Host "  chkdsk Ã§alÄ±ÅŸÄ±yor: $secimAdi" -ForegroundColor Cyan
    Write-Host "  LÃ¼tfen bekleyin..." -ForegroundColor $Tema.Soluk
    Write-Host ""

    $arguman = "$harf`: $parametre"         
    $sonuc = Start-Process -FilePath "chkdsk.exe" `
                           -ArgumentList $arguman `
                           -NoNewWindow -Wait -PassThru

    Write-Host ""
    if ($sonuc.ExitCode -eq 0) {
        Write-Result $true "$secimAdi â†’ temiz, hata bulunamadÄ±."
    } elseif ($sonuc.ExitCode -eq 1) {
        Write-Result $true "$secimAdi â†’ hatalar bulundu ve dÃ¼zeltildi."
    } else {
        Write-Result $false "$secimAdi â†’ tarama bitti (Kod: $($sonuc.ExitCode))."
    }

    Write-Host ""
    Read-Host "  Devam etmek iÃ§in Enter'a basÄ±n"
}

# ===================== SÃœRÃœCÃœ VE UYGULAMA YÃ–NETÄ°MÄ° =====================

function Backup-Drivers {
    Show-Header "SÃœRÃœCÃœ YEDEKLE"
    $hedef = Select-Folder "SÃ¼rÃ¼cÃ¼lerin yedekleneceÄŸi klasÃ¶rÃ¼ seÃ§in"
    if (-not $hedef) { Write-Result $false "Ä°ÅŸlem iptal edildi."; Write-Host ""; Read-Host "  Devam etmek iÃ§in Enter'a basÄ±n"; return }

    $klasor = Join-Path $hedef ("Surucu_Yedek_" + (Get-Date -Format "yyyyMMdd_HHmm"))
    Write-Host ""
    $onay = Read-Host "  SÃ¼rÃ¼cÃ¼ler '$klasor' klasÃ¶rÃ¼ne yedeklenecek. OnaylÄ±yor musunuz? (E/H)"
    if ($onay -ne "E" -and $onay -ne "e") {
        Write-Result $false "Ä°ÅŸlem iptal edildi."; Write-Host ""; Read-Host "  Devam etmek iÃ§in Enter'a basÄ±n"; return
    }

    $eskiProgress = $ProgressPreference
    $ProgressPreference = 'SilentlyContinue'
    try {
        New-Item -Path $klasor -ItemType Directory -Force | Out-Null

        Write-Host "  SÃ¼rÃ¼cÃ¼ler yedekleniyor, lÃ¼tfen bekleyin..." -ForegroundColor Yellow
        Write-Host "  (Her yedeklenen sÃ¼rÃ¼cÃ¼ canlÄ± listelenecek.)" -ForegroundColor DarkGray
        Write-Host ""

       $sayac = 0
       Export-WindowsDriver -Online -Destination $klasor -ErrorAction Stop | ForEach-Object {
            $sayac++
            $no = $sayac.ToString().PadLeft(3)
            $ad = if ($_.OriginalFileName) { Split-Path $_.OriginalFileName -Leaf } else { "(bilinmeyen sÃ¼rÃ¼cÃ¼)" }
            $sinif = if ($_.ClassName) { $_.ClassName } else { "Genel" }
            Write-Host ("  [" + $no + "] ") -ForegroundColor Cyan -NoNewline
            Write-Host $ad -ForegroundColor Gray -NoNewline
            Write-Host ("   (" + $sinif + ")") -ForegroundColor DarkGray

            Write-Progress -Activity "SÃ¼rÃ¼cÃ¼ler yedekleniyor" `
                           -Status "$sayac sÃ¼rÃ¼cÃ¼ yedeklendi..." `
                           -CurrentOperation $ad
        }
        Write-Progress -Activity "SÃ¼rÃ¼cÃ¼ler yedekleniyor" -Completed

        Write-Host ""
        if ($sayac -gt 0) {
            Write-Result $true "$sayac sÃ¼rÃ¼cÃ¼ yedeklendi: $klasor"
        } else {
            Write-Result $false "Yedeklenecek sÃ¼rÃ¼cÃ¼ bulunamadÄ±."
        }
    } catch {
        Write-Result $false "SÃ¼rÃ¼cÃ¼ yedeklenemedi: $($_.Exception.Message)"
    } finally {
        $ProgressPreference = $eskiProgress
    }
    Write-Host ""
    Read-Host "  Devam etmek iÃ§in Enter'a basÄ±n"
}

function Restore-Drivers {
    Show-Header "SÃœRÃœCÃœ GERÄ° YÃœKLE"
    $kaynak = Select-Folder "YedeklenmiÅŸ sÃ¼rÃ¼cÃ¼ klasÃ¶rÃ¼nÃ¼ seÃ§in"
    if (-not $kaynak) { Write-Result $false "Ä°ÅŸlem iptal edildi."; Write-Host ""; Read-Host "  Devam etmek iÃ§in Enter'a basÄ±n"; return }

    Write-Host ""
    $onay = Read-Host "  SÃ¼rÃ¼cÃ¼ler '$kaynak' klasÃ¶rÃ¼nden geri yÃ¼klenecek. Emin misiniz? (E/H)"
    if ($onay -ne "E" -and $onay -ne "e") {
        Write-Result $false "Ä°ÅŸlem iptal edildi."; Write-Host ""; Read-Host "  Devam etmek iÃ§in Enter'a basÄ±n"; return
    }
    try {
        $infVar = Get-ChildItem -Path $kaynak -Filter *.inf -Recurse -ErrorAction SilentlyContinue
        if (-not $infVar) {
            Write-Result $false "SeÃ§ilen klasÃ¶rde .inf sÃ¼rÃ¼cÃ¼ dosyasÄ± bulunamadÄ±."
            Write-Host ""
            Read-Host "  Devam etmek iÃ§in Enter'a basÄ±n"
            return
        }

        Write-Host "  SÃ¼rÃ¼cÃ¼ler yÃ¼kleniyor, lÃ¼tfen bekleyin..." -ForegroundColor Yellow
        pnputil /add-driver "$kaynak\*.inf" /subdirs /install
        $kod = $LASTEXITCODE

        switch ($kod) {
            0 {
                Write-Result $true "SÃ¼rÃ¼cÃ¼ler geri yÃ¼klendi."
            }
            259 {
                Write-Result $true "TÃ¼m sÃ¼rÃ¼cÃ¼ler zaten gÃ¼ncel â€” yÃ¼klenecek yeni sÃ¼rÃ¼cÃ¼ yoktu."
            }
            3010 {
                Write-Result $true "SÃ¼rÃ¼cÃ¼ler geri yÃ¼klendi. DeÄŸiÅŸikliklerin tamamlanmasÄ± iÃ§in yeniden baÅŸlatÄ±n."
            }
            default {
                Write-Result $false "SÃ¼rÃ¼cÃ¼ geri yÃ¼kleme tamamlandÄ± ancak bazÄ± sÃ¼rÃ¼cÃ¼ler yÃ¼klenemedi (Kod: $kod)."
            }
        }
    } catch {
        Write-Result $false "SÃ¼rÃ¼cÃ¼ geri yÃ¼klenemedi: $($_.Exception.Message)"
    }
    Write-Host ""
    Read-Host "  Devam etmek iÃ§in Enter'a basÄ±n"
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
    Show-Header "UYGULAMA LÄ°STESÄ° DIÅA/Ä°Ã‡E AKTAR"
    Write-Host "  1) YÃ¼klÃ¼ uygulama listesini dÄ±ÅŸa aktar (JSON)" -ForegroundColor White
    Write-Host "  2) JSON dosyasÄ±ndan uygulamalarÄ± iÃ§e aktar (kur)" -ForegroundColor White
    Write-Host ""

    if (-not $WingetVar) {
        Write-Result $false "Winget bulunamadÄ±, bu iÅŸlem yapÄ±lamÄ±yor."
        Write-Host ""
        Read-Host "  Devam etmek iÃ§in Enter'a basÄ±n"
        return
    }

    $sec = Read-Host "  SeÃ§iminiz (1/2)"
    if ($sec -eq "1") {
        $hedef = Select-Folder "JSON'un kaydedileceÄŸi klasÃ¶rÃ¼ seÃ§in"
        if ($hedef) {
            $dosya = Join-Path $hedef "uygulama_listesi.json"
            winget export -o "$dosya" --accept-source-agreements | Out-Null
            if (Test-Path $dosya) {
                $boyutKB = [math]::Round((Get-Item $dosya).Length / 1KB, 1)
                Write-Result $true "Liste dÄ±ÅŸa aktarÄ±ldÄ±: $dosya ($boyutKB KB)"
            } else {
                Write-Result $false "DÄ±ÅŸa aktarma baÅŸarÄ±sÄ±z: dosya oluÅŸturulamadÄ±."
            }
        } else {
            Write-Result $false "Ä°ÅŸlem iptal edildi."
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
                Write-Result $false "SeÃ§ilen dosya geÃ§erli bir JSON deÄŸil veya boÅŸ. Ä°ÅŸlem durduruldu."
                Write-Host ""
                Read-Host "  Devam etmek iÃ§in Enter'a basÄ±n"
                return
            }

            $onay = Read-Host "  '$dosya' iÃ§indeki uygulamalar kurulacak. OnaylÄ±yor musunuz? (E/H)"
            if ($onay -eq "E" -or $onay -eq "e") {

                Write-Host ""
                Write-Host "  LÃ¼tfen bekleyin, uygulamalar kuruluyor (canlÄ± akacak)..." -ForegroundColor DarkGray
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
                Show-Line "  Ä°Ã‡E AKTARMA Ã–ZETÄ°" $Tema.Vurgu
                Show-Divider
                Show-Line ("  Zaten kurulu      : " + $zatenKurulu + " uygulama") $Tema.Metin
                Show-Line ("  Yeni kurulan      : " + $yeniKurulan + " uygulama") $Tema.Basari
                Show-Divider
                Show-Line ("  Ä°ÅŸlenen toplam    : " + $toplam + " uygulama") $Tema.Baslik
                Show-Bottom
                Write-Host ""

                if ($kod -eq 0) {
                    if ($yeniKurulan -gt 0) {
                        Write-Result $true "$yeniKurulan uygulama yeni kuruldu, $zatenKurulu uygulama zaten kuruluydu."
                    } else {
                        Write-Result $true "TÃ¼m uygulamalar ($zatenKurulu) zaten kuruluydu â€” yeni kurulum gerekmedi."
                    }
                } else {
                    Write-Result $false "Ä°Ã§e aktarma tamamlandÄ± ancak bazÄ± uygulamalar kurulamadÄ± (Kod: $kod)."
                }
            } else {
                Write-Result $false "Ä°ÅŸlem iptal edildi."
            }
        } else {
            Write-Result $false "Ä°ÅŸlem iptal edildi."
        }
    } else {
        Write-Result $false "GeÃ§ersiz seÃ§im."
    }
    Write-Host ""
    Read-Host "  Devam etmek iÃ§in Enter'a basÄ±n"
}
function App-Uninstall {
    Show-Header "UYGULAMA KALDIR"
    Write-Host "  YÃ¼klÃ¼ tÃ¼m uygulamalar listeleniyor..." -ForegroundColor Yellow
    Write-Host ""
    if (-not $WingetVar) {
        Write-Result $false "Winget bulunamadÄ±."
        Write-Host ""
        Read-Host "  Devam etmek iÃ§in Enter'a basÄ±n"
        return
    }
    winget list
    Write-Host ""
    Write-Host "  YukarÄ±daki listeden kaldÄ±rmak istediÄŸiniz uygulamanÄ±n" -ForegroundColor Cyan
    Write-Host "  ID veya Ad bilgisini girin (boÅŸ bÄ±rakÄ±p Enter = iptal)." -ForegroundColor Cyan
    Write-Host ""
    $hedef = Read-Host "  KaldÄ±rÄ±lacak uygulama (ID veya Ad)"
    if ([string]::IsNullOrWhiteSpace($hedef)) {
        Write-Result $false "Ä°ÅŸlem iptal edildi."
        Write-Host ""; Read-Host "  Devam etmek iÃ§in Enter'a basÄ±n"; return
    }

    $gercekAd = $hedef

    $onay = Read-Host "  '$hedef' kaldÄ±rÄ±lsÄ±n mÄ±? (E/H)"
    if ($onay -ne "E" -and $onay -ne "e") {
        Write-Result $false "Ä°ÅŸlem iptal edildi."
        Write-Host ""; Read-Host "  Devam etmek iÃ§in Enter'a basÄ±n"; return
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
            Write-Host "  ID ile bulunamadÄ±, Ad ile deneniyor..." -ForegroundColor DarkGray
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
            Write-Result $false "'$gercekAd' zaten yÃ¼klÃ¼ deÄŸildi (kaldÄ±rÄ±lacak bir ÅŸey yok)."
        } elseif (-not $halaVar) {
            Write-Result $true "'$gercekAd' baÅŸarÄ±yla kaldÄ±rÄ±ldÄ± ve doÄŸrulandÄ±."
        } else {
            Write-Result $false "'$gercekAd' hÃ¢lÃ¢ yÃ¼klÃ¼ gÃ¶rÃ¼nÃ¼yor (Kod: $kod). KaldÄ±rma tamamlanamadÄ±."
        }
    } catch {
        Write-Result $false "KaldÄ±rma baÅŸarÄ±sÄ±z: $($_.Exception.Message)"
    }
    Write-Host ""
    Read-Host "  Devam etmek iÃ§in Enter'a basÄ±n"
}
function Show-Help {
    Show-Header "YARDIM / HAKKINDA"
    Write-Host "  Bilgisayar AracÄ±" -ForegroundColor $Tema.Vurgu
    Write-Host "  HazÄ±rlayan : Mehmet IÅIK" -ForegroundColor $Tema.Metin
    Write-Host "  GÃ¼ncelleme : 04.07.2026" -ForegroundColor $Tema.Metin
    Write-Host ""
    Write-Host "  Bu araÃ§; uygulama kurulumu, sistem bilgisi," -ForegroundColor $Tema.Metin
    Write-Host "  bakÄ±m/temizlik ve sÃ¼rÃ¼cÃ¼ yÃ¶netimi saÄŸlar." -ForegroundColor $Tema.Metin
    Write-Host ""
    Write-Host "  â€¢ Numara yazÄ±p Enter ile iÅŸlemi seÃ§in." -ForegroundColor $Tema.Soluk
    Write-Host "  â€¢ 0 yazÄ±p Enter ile programdan Ã§Ä±kÄ±n." -ForegroundColor $Tema.Soluk
    Write-Host ""
    if ($WingetVar) {
        Write-Host "  â€¢ Winget (paket yÃ¶neticisi): YÃœKLÃœ âœ“" -ForegroundColor $Tema.Basari
    } else {
        Write-Host "  â€¢ Winget (paket yÃ¶neticisi): YÃœKLÃœ DEÄÄ°L âœ—" -ForegroundColor $Tema.Hata
        Write-Host "    Kurulum iÃ§in aÅŸaÄŸÄ±dan 'E' seÃ§ebilirsiniz." -ForegroundColor $Tema.Soluk
    }
    Write-Host ""

    $wh = Read-Host "  Winget kurulum yardÄ±mÄ±nÄ± gÃ¶rÃ¼ntÃ¼lemek ister misiniz? (E/H)"
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
            Write-Host "â•‘" -ForegroundColor $Tema.Cerceve -NoNewline
            Write-Host (" " + $numara) -ForegroundColor $Tema.Vurgu -NoNewline
            Write-Host ($satirAd + (" " * ($bosluk - 1))) -ForegroundColor $Tema.Baslik -NoNewline
            Write-Host "â•‘" -ForegroundColor $Tema.Cerceve
        }
        Show-Divider
        Show-Line "  T) SeÃ§ili numaralarÄ± kur (Ã¶rn: 1,3,5)" $Tema.Vurgu
        Show-Line "  H) TÃ¼mÃ¼nÃ¼ kur" $Tema.Vurgu
        Show-Line "  0) Ana menÃ¼ye dÃ¶n" $Tema.Soluk
        Show-Bottom
        Write-Host ""
        $sec = Read-Host "  SeÃ§iminiz"

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
                Write-Result $false "Winget kurulu olmadÄ±ÄŸÄ± iÃ§in uygulama kurulumu yapÄ±lamÄ±yor."
                Write-Host ""
                Write-Host "  Winget'i kurmak iÃ§in ana menÃ¼ > 26) YardÄ±m bÃ¶lÃ¼mÃ¼nÃ¼ kullanÄ±n" -ForegroundColor Yellow
                Write-Host "  veya programÄ± yeniden baÅŸlatÄ±n (aÃ§Ä±lÄ±ÅŸta otomatik kurulmayÄ± dener)." -ForegroundColor Yellow
                Write-Host ""
                Read-Host "  Devam etmek iÃ§in Enter'a basÄ±n"
                continue   
            }
        }

        if ($sec -eq "H" -or $sec -eq "h") {
            foreach ($u in $Uygulamalar) {
                Install-App $u.Ad $u.Id $u.Kaynak
            }
            Write-Host ""; Read-Host "  Devam etmek iÃ§in Enter'a basÄ±n"
        }
        elseif ($sec -eq "T" -or $sec -eq "t" -or $sec -match "[0-9]") {
            $numaralar = $sec -split "[,\s]+" | Where-Object { $_ -match "^\d+$" }
            foreach ($n in $numaralar) {
                $secilen = $Uygulamalar | Where-Object { $_.No -eq [int]$n }
                if ($secilen) {
                    Install-App $secilen.Ad $secilen.Id $secilen.Kaynak
                }
            }
            Write-Host ""; Read-Host "  Devam etmek iÃ§in Enter'a basÄ±n"
        }
    }
}
# ===================== TEK DÃœZ MENÃœ (FLAT) =====================
$Menu = @(
    # ===== SOL SÃœTUN (1â€“14) =====
    @{ No = 1;  Grup = "UYGULAMA";  Ad = "Uygulama Kurulumu (liste)";          Eylem = { Invoke-AppMenu } }
    @{ No = 2;  Grup = "UYGULAMA";  Ad = "TÃ¼m UygulamalarÄ± GÃ¼ncelle";          Eylem = { Update-AllApps } }
    @{ No = 3;  Grup = "UYGULAMA";  Ad = "Uygulama Ara ve Kur (winget)";       Eylem = { Search-App } }
    @{ No = 4;  Grup = "UYGULAMA";  Ad = "Uygulama Listesi DÄ±ÅŸa/Ä°Ã§e Aktar";    Eylem = { App-ExportImport } }
    @{ No = 5;  Grup = "UYGULAMA";  Ad = "Uygulama KaldÄ±r";                    Eylem = { App-Uninstall } }

    @{ No = 6;  Grup = "TEMÄ°ZLÄ°K";  Ad = "GeÃ§ici DosyalarÄ± Temizle";           Eylem = { Clean-Temp } }
    @{ No = 7;  Grup = "TEMÄ°ZLÄ°K";  Ad = "Windows LoglarÄ±nÄ± Temizle";          Eylem = { Clean-Logs } }
    @{ No = 8;  Grup = "TEMÄ°ZLÄ°K";  Ad = "Windows Update Ã–nbelleÄŸi";           Eylem = { Clean-WinUpdate } }
    @{ No = 9;  Grup = "TEMÄ°ZLÄ°K";  Ad = "Geri DÃ¶nÃ¼ÅŸÃ¼m Kutusunu BoÅŸalt";       Eylem = { Clean-RecycleBin } }
    @{ No = 10; Grup = "TEMÄ°ZLÄ°K";  Ad = "Disk Temizleme (cleanmgr)";          Eylem = { Clean-Disk } }
    @{ No = 11; Grup = "TEMÄ°ZLÄ°K";  Ad = "Ekran KartÄ± SÃ¼rÃ¼cÃ¼ ArtÄ±klarÄ±";       Eylem = { Clean-GpuLeftovers } }

    @{ No = 12; Grup = "SÃœRÃœCÃœ";    Ad = "SÃ¼rÃ¼cÃ¼ Yedekle";                     Eylem = { Backup-Drivers } }
    @{ No = 13; Grup = "SÃœRÃœCÃœ";    Ad = "SÃ¼rÃ¼cÃ¼ Geri YÃ¼kle";                  Eylem = { Restore-Drivers } }

    # ===== SAÄ SÃœTUN (15â€“27) =====
    @{ No = 14; Grup = "BAKIM";     Ad = "Sistem ve Disk OnarÄ±mÄ±";   	       Eylem = { Repair-Disk } }
    @{ No = 15; Grup = "BAKIM";     Ad = "GÃ¼venli USB OluÅŸtur (KorumalÄ±)";     Eylem = { Protect-USB } }
    @{ No = 16; Grup = "BAKIM";     Ad = "Windows GÃ¼ncellemelerini Tara";      Eylem = { Start-WindowsUpdate } }
    @{ No = 17; Grup = "BAKIM";     Ad = "AÄŸ AyarlarÄ±nÄ± SÄ±fÄ±rla";              Eylem = { Reset-Network } }
    @{ No = 18; Grup = "BAKIM";     Ad = "Geri YÃ¼kleme NoktasÄ± OluÅŸtur";       Eylem = { New-RestorePoint } }
    @{ No = 19; Grup = "BAKIM";     Ad = "YazÄ±cÄ± KuyruÄŸunu Temizle";           Eylem = { Clear-PrintQueue } }

    @{ No = 20; Grup = "BÄ°LGÄ°";     Ad = "Sistem Bilgileri";                   Eylem = { Show-SystemInfo } }
    @{ No = 21; Grup = "BÄ°LGÄ°";     Ad = "Disk Ã–zeti";                         Eylem = { Show-DiskSummary } }
    @{ No = 22; Grup = "BÄ°LGÄ°";     Ad = "Disk SaÄŸlÄ±ÄŸÄ± (SMART)";               Eylem = { Show-DiskHealth } }
    @{ No = 23; Grup = "BÄ°LGÄ°";     Ad = "BaÅŸlangÄ±Ã§ ProgramlarÄ±";              Eylem = { Show-Startup } }
    @{ No = 24; Grup = "BÄ°LGÄ°";     Ad = "Sistem SaÄŸlÄ±k Ã–zeti";                Eylem = { Show-HealthSummary } }

    @{ No = 25; Grup = "DÄ°ÄER";     Ad = "YÃ¶netim KlasÃ¶rleri OluÅŸtur";         Eylem = { New-AdminFolders } }
    @{ No = 26; Grup = "DÄ°ÄER";     Ad = "YardÄ±m / HakkÄ±nda";                  Eylem = { Show-Help } }
)

# ===================== YARDIMCI: MENÃœ KOLONU OLUÅTUR =====================
function Get-Kolon {
    param(
        [string[]]$Gruplar,
        [hashtable]$Ikon,
        [array]$MenuListesi
    )
    $satirlar = @()
    foreach ($g in $Gruplar) {
        $ik = if ($Ikon.ContainsKey($g)) { $Ikon[$g] } else { "â€¢" }
        $satirlar += [pscustomobject]@{ Tip = "Baslik"; Metin = (" " + $ik + " " + $g) }
        foreach ($m in ($MenuListesi | Where-Object { $_.Grup -eq $g })) {
            $satirlar += [pscustomobject]@{ Tip = "Oge"; No = $m.No; Ad = $m.Ad }
        }
    }
    return ,$satirlar
}

# ===================== ANA MENÃœ (TEK DÃœZ / FLAT) =====================
function Show-MainMenu {
    Clear-Host

    # ===== ÃœST BAÅLIK BANDI =====
    Write-Host ("â•”" + ("â•" * $BoxWidth) + "â•—") -ForegroundColor $Tema.Cerceve

    # 1. Ãœst BoÅŸluk (Nefes PayÄ±)
    Write-Host "â•‘" -ForegroundColor $Tema.Cerceve -NoNewline
    Write-Host (" " * $BoxWidth) -NoNewline
    Write-Host "â•‘" -ForegroundColor $Tema.Cerceve

    # 2. Ana BaÅŸlÄ±k
    $baslik = "âœ¦  B Ä° L G Ä° S A Y A R   A R A C I  âœ¦"
    $bPad = [math]::Max(1, [math]::Floor(($BoxWidth - $baslik.Length) / 2))
    Write-Host "â•‘" -ForegroundColor $Tema.Cerceve -NoNewline
    Write-Host ((" " * $bPad) + $baslik + (" " * ($BoxWidth - $baslik.Length - $bPad))) -ForegroundColor $Tema.Vurgu -NoNewline
    Write-Host "â•‘" -ForegroundColor $Tema.Cerceve

    # 3. Ä°Ã§ AyraÃ§ (BaÅŸlÄ±k ile Slogan arasÄ± ince Ã§izgi)
    $ayracUzunluk = $BoxWidth - 6 
    $ayrac = "â”€" * $ayracUzunluk
    $aPad = [math]::Floor(($BoxWidth - $ayracUzunluk) / 2)
    Write-Host "â•‘" -ForegroundColor $Tema.Cerceve -NoNewline
    Write-Host ((" " * $aPad) + $ayrac + (" " * ($BoxWidth - $ayracUzunluk - $aPad))) -ForegroundColor $Tema.Soluk -NoNewline
    Write-Host "â•‘" -ForegroundColor $Tema.Cerceve

    # 4. Slogan
    $slogan = "Kur â€¢ GÃ¼ncelle â€¢ Temizle â€¢ Yedekle â€¢ Onar"
    $sPad = [math]::Max(1, [math]::Floor(($BoxWidth - $slogan.Length) / 2))
    Write-Host "â•‘" -ForegroundColor $Tema.Cerceve -NoNewline
    Write-Host ((" " * $sPad) + $slogan + (" " * ($BoxWidth - $slogan.Length - $sPad))) -ForegroundColor $Tema.Soluk -NoNewline
    Write-Host "â•‘" -ForegroundColor $Tema.Cerceve

    # 5. Alt BoÅŸluk (Nefes PayÄ±)
    Write-Host "â•‘" -ForegroundColor $Tema.Cerceve -NoNewline
    Write-Host (" " * $BoxWidth) -NoNewline
    Write-Host "â•‘" -ForegroundColor $Tema.Cerceve

    # ===== CANLI MÄ°NÄ° SÄ°STEM DURUMU =====
    $durum = " Sistem durumu okunuyor..."
    try {
        $os = Get-CimInstance Win32_OperatingSystem -ErrorAction SilentlyContinue
        $cDisk = Get-CimInstance Win32_LogicalDisk -Filter "DeviceID='C:'" -ErrorAction SilentlyContinue
        
# Disk HesabÄ±
        $cTop = [math]::Round($cDisk.Size / 1GB, 0)
        $cBos = [math]::Round($cDisk.FreeSpace / 1GB, 0)
        $cYuzde = if ($cTop -gt 0) { [math]::Round((($cTop - $cBos) / $cTop) * 100) } else { 0 }
        
        # RAM HesabÄ± (Hem fiziksel hem sanal makine uyumlu)
        $ramTop = [math]::Round($os.TotalVisibleMemorySize / 1024 / 1024)
        $ramBos = [math]::Round($os.FreePhysicalMemory / 1024 / 1024, 1)
        # GÃ¼ncellenmiÅŸ Durum Ã‡Ä±ktÄ±sÄ±
        $durum = " ğŸ’½ C: %$cYuzde dolu ($cBos GB boÅŸ)   ğŸ§  RAM: $ramBos GB boÅŸ / $ramTop GB"
    } catch {}

    Write-Host ("â•Ÿ" + ("â”€" * $BoxWidth) + "â•¢") -ForegroundColor $Tema.Cerceve
    
    $dPad = [math]::Max(1, $BoxWidth - $durum.Length)
    Write-Host "â•‘" -ForegroundColor $Tema.Cerceve -NoNewline
    Write-Host ($durum + (" " * $dPad)).Substring(0, $BoxWidth) -ForegroundColor $Tema.Basari -NoNewline
    Write-Host "â•‘" -ForegroundColor $Tema.Cerceve
    Write-Host ("â•Ÿ" + ("â”€" * $BoxWidth) + "â•¢") -ForegroundColor $Tema.Cerceve
    
    # ===== Ä°KONLU GRUP DAÄILIMI =====
    $ikon = @{
        "UYGULAMA" = "ğŸ“¦"; "BÄ°LGÄ°" = "â„¹ï¸ "; "TEMÄ°ZLÄ°K" = "ğŸ§¹"
        "BAKIM"    = "ğŸ”§"; "SÃœRÃœCÃœ" = "ğŸ’¾"; "DÄ°ÄER"    = "âš™ï¸ "
    }
    $solGruplar = @("UYGULAMA", "TEMÄ°ZLÄ°K", "SÃœRÃœCÃœ")
    $sagGruplar = @("BAKIM", "BÄ°LGÄ°", "DÄ°ÄER")

    $solKolon = Get-Kolon -Gruplar $solGruplar -Ikon $ikon -MenuListesi $Menu
    $sagKolon = Get-Kolon -Gruplar $sagGruplar -Ikon $ikon -MenuListesi $Menu

    $satirSayisi = [math]::Max($solKolon.Count, $sagKolon.Count)
    $kolGenislik = [math]::Floor(($BoxWidth - 1) / 2)
    $sagGen = $BoxWidth - $kolGenislik - 1

    for ($i = 0; $i -lt $satirSayisi; $i++) {
        $solSatir = if ($i -lt $solKolon.Count) { $solKolon[$i] } else { $null }
        $sagSatir = if ($i -lt $sagKolon.Count) { $sagKolon[$i] } else { $null }

        Write-Host "â•‘" -ForegroundColor $Tema.Cerceve -NoNewline

        # --- SOL HÃœCRE ---
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

        Write-Host "â”‚" -ForegroundColor $Tema.Cerceve -NoNewline

        # --- SAÄ HÃœCRE ---
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

        Write-Host "â•‘" -ForegroundColor $Tema.Cerceve
    }

    # ===== ALT BANT =====
    Write-Host ("â•Ÿ" + ("â”€" * $BoxWidth) + "â•¢") -ForegroundColor $Tema.Cerceve

    $wtKurulu = $null -ne (Get-Command wt.exe -ErrorAction SilentlyContinue)
    if (-not $wtKurulu) {
        $wtPath = "$env:LOCALAPPDATA\Microsoft\WindowsApps\wt.exe"
        if (Test-Path $wtPath) { $wtKurulu = $true }
    }
    if (-not $wtKurulu) {
        $ipucu = "  ğŸ’¡ Daha modern bir gÃ¶rÃ¼nÃ¼m iÃ§in Windows Terminal Ã¶nerilir."
        $ipucu2 = "     Kurulum: MenÃ¼ 1 (Uygulama Kurulumu) â–¸ 15 numara."
        Show-Line $ipucu "Yellow"
        Show-Line $ipucu2 $Tema.Soluk
        Write-Host ("â•Ÿ" + ("â”€" * $BoxWidth) + "â•¢") -ForegroundColor $Tema.Cerceve
    }

    Show-Line "  â¤ Numara yazÄ±p Enter'a basÄ±n  â€¢  0) Ã‡Ä±kÄ±ÅŸ" $Tema.Vurgu
    Show-Line "  Mehmet IÅIK  â€¢  Bilgisayar AracÄ±  â€¢  v2026" $Tema.Soluk
    Write-Host ("â•š" + ("â•" * $BoxWidth) + "â•") -ForegroundColor $Tema.Cerceve
    Write-Host ""
}

# ===================== ANA DÃ–NGÃœ (TEK MENÃœ) =====================
$cikis = $false
do {
    try {
        Show-MainMenu
        $sec = Read-Host "  SeÃ§iminiz"

        if ($sec -eq "0") {
            $cikis = $true
        }
        elseif ($sec -match "^\d+$") {
            $secilen = $Menu | Where-Object { $_.No -eq [int]$sec }
            if ($secilen) {
                & $secilen.Eylem
            } else {
                Write-Host ""
                Write-Host "  GeÃ§ersiz numara: $sec" -ForegroundColor Red
                Start-Sleep -Milliseconds 900
            }
        }
        else {
            Write-Host ""
            Write-Host "  LÃ¼tfen geÃ§erli bir numara girin." -ForegroundColor Red
            Start-Sleep -Milliseconds 900
        }
    }
    catch {
        [Console]::CursorVisible = $true
        Write-Host ""
        Write-Host "  Ä°ÅLEM SIRASINDA HATA OLUÅTU:" -ForegroundColor Red
        Write-Host ("  " + $_.Exception.Message) -ForegroundColor Red
        Write-Host ""
        Read-Host "  Devam etmek iÃ§in Enter'a basÄ±n"
    }
} while (-not $cikis)

Clear-Host
Write-Host "Program kapatÄ±ldÄ±. Ä°yi gÃ¼nler, Mehmet IÅIK!" -ForegroundColor Cyan

