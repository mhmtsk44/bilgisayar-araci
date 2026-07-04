<#
    Uygulama İndirme-Güncelleme-Sürücü Yedek Alma-Temizleme Aracı
    Hazırlayan: Mehmet IŞIK
    Güncelleme: 04.07.2026
    Kullanım: Sağ tık -> "PowerShell ile çalıştır" veya yönetici PowerShell'de:
              powershell -ExecutionPolicy RemoteSigned -File "Bilgisayar_Araci.ps1"
    NOT: Dosyayı "UTF-8 with BOM" olarak kaydedin (Türkçe + çerçeve karakterleri için).
#>

# ===================== YÖNETİCİ KONTROLÜ + TEK PENCERE BAŞLATMA =====================

function Test-Admin {
    $kimlik = [Security.Principal.WindowsIdentity]::GetCurrent()
    $rol = New-Object Security.Principal.WindowsPrincipal($kimlik)
    return $rol.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

# ================================================================
#  WINGET KURULUM BETIGI - Nihai Surum v2 (Sahaya Ozel)
#  Iyilestirmeler: Hata loglama + Dinamik UI.Xaml + Ag Dalgalanma Korumasi + LTSC Guncelleme
# ================================================================

# Ağ bağlantısı sorunlarını önlemek için TLS 1.2'yi zorla (Eski sistemler için kritik)
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
    param([string]$Soru = "Bu işlemi yapmak istediğinize emin misiniz?")
    Write-Host ""
    $cevap = Read-Host "  $Soru (E/H)"
    return ($cevap -eq "E" -or $cevap -eq "e")
}

# ===================== LTSC / LTSB TESPİTİ =====================
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

# ===================== ZAMAN AŞIMLI ÇALIŞTIRMA YARDIMCISI =====================
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

# ===================== DOSYA İNDİRME YARDIMCISI (Yeniden Deneme Korumalı) =====================
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

# ===================== NUGET SÜRÜM SORGUSU =====================
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

# ===================== UI.XAML TAMAMEN DİNAMİK ÇÖZÜM =====================
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

# ===================== GEÇİCİ DOSYA TEMİZLİĞİ =====================
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

# ===================== LTSC GÜNCELLEME GÖREVİ =====================
function Kur-WingetLTSCGuncellemeGorevi {
    $GorevAdi = "Winget-OtomatikGuncelleme-LTSC"
    Write-Host "        LTSC otomatik güncelleme görevi ayarlanıyor..." -ForegroundColor DarkGray
    Yaz-Log "LTSC guncelleme gorevi olusturma baslatildi."

    try {
        Unregister-ScheduledTask -TaskName $GorevAdi -Confirm:$false -ErrorAction SilentlyContinue

        $tetikleyici = New-ScheduledTaskTrigger -Weekly -DaysOfWeek Friday -At 12:00pm
        $psKomut = "Install-PackageProvider -Name NuGet -Force -Scope CurrentUser -ErrorAction SilentlyContinue; Set-PSRepository -Name PSGallery -InstallationPolicy Trusted -ErrorAction SilentlyContinue; Install-Script -Name winget-install -Force -Scope CurrentUser -ErrorAction SilentlyContinue; `$p = (Get-InstalledScript winget-install).InstalledLocation; & (Join-Path `$p 'winget-install.ps1') -Force"
        
        $eylem = New-ScheduledTaskAction -Execute "powershell.exe" -Argument "-WindowStyle Hidden -NonInteractive -NoProfile -Command `"$psKomut`""

        Register-ScheduledTask -TaskName $GorevAdi -Trigger $tetikleyici -Action $eylem -Description "LTSC sistemlerde Winget'i guncel tutmak icin haftalik kontrol yapar." -ErrorAction Stop | Out-Null
        
        Yaz-Log "LTSC guncelleme gorevi basariyla kaydedildi."
    } catch {
        Write-Host "        Güncelleme görevi oluşturulamadı!" -ForegroundColor Red
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

# ===================== WINGET KURULUM ANA FONKSİYONU =====================
function Install-Winget {
    param([switch]$Sessiz)
    
    if (-not $Sessiz) { Write-Host "Winget durumu kontrol ediliyor..." -ForegroundColor Cyan }
    if (Get-Command winget -ErrorAction SilentlyContinue) {
        if (-not $Sessiz) { Write-Host "Winget bu sistemde zaten kurulu!" -ForegroundColor Green }
        Yaz-Log "Winget zaten kurulu."
        
        # Zaten kuruluysa LTSC ise yine de görev atayalım (önceden kurulmuş ama görev atılmamış olabilir)
        if (Test-LTSC) { Kur-WingetLTSCGuncellemeGorevi }
        return $true
    }
Write-Host ""
    Write-Host "  Sistemde Winget (Windows Paket Yöneticisi) bulunamadı." -ForegroundColor Yellow
    Write-Host "  Uygulama indirme ve güncelleme menülerinin çalışması için gereklidir." -ForegroundColor DarkGray
    if (-not (Confirm-Islem "Winget şimdi kurulsun mu?")) {
        Write-Host "  Winget kurulumu atlandı. Winget gerektiren menüler çalışmayacaktır." -ForegroundColor Red
        Yaz-Log "Winget kurulumu kullanıcı tarafından iptal edildi." 'UYARI'
        Start-Sleep -Seconds 2
        return $false
    }
    Write-Host "Sistem mimarisi inceleniyor..." -ForegroundColor Cyan
    $ltsc = Test-LTSC

    if ($ltsc) {
        Write-Host "SİSTEM TESPİTİ: LTSC / LTSB Sürümü!" -ForegroundColor Yellow
        Write-Host "Özel LTSC yöntemi (PSGallery) başlatılıyor..." -ForegroundColor DarkGray

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
                # --- GÜNCELLEME GÖREVİ BURADA ÇAĞRILIYOR ---
                Kur-WingetLTSCGuncellemeGorevi
            }
        } catch {
            Write-Host "LTSC kurulumu sirasinda hata." -ForegroundColor Red
            Yaz-Log "LTSC kurulum istisnasi: $($_.Exception.Message)" 'HATA'
        }

    } else {
        Write-Host "SİSTEM TESPİTİ: Standart Windows Sürümü." -ForegroundColor Green
        Write-Host "Normal kurulum (App Installer) başlatılıyor..." -ForegroundColor DarkGray
        
        # Indir-Dosya kullanılarak standart indirme daha güvenli hale getirildi
        $getwinget = Join-Path $env:TEMP "getwinget.msixbundle"
        if (Indir-Dosya "https://aka.ms/getwinget" $getwinget 120) {
            try { Add-AppxPackage -Path $getwinget -ErrorAction Stop; Yaz-Log "Standart paket kuruldu." }
            catch { Yaz-Log "Standart kurulum hatasi: $($_.Exception.Message)" 'HATA' }
        }
    }

    Start-Sleep -Seconds 3
    if (Get-Command winget -ErrorAction SilentlyContinue) {
        Write-Host "İşlem Tamamlandı: Winget başarıyla kuruldu (birincil yol)!" -ForegroundColor Green
        Temizle-GeciciDosyalar
        return $true
    }

    Write-Host "Birincil yol sonuc vermedi -> manuel yedek yola geciliyor..." -ForegroundColor DarkYellow
    Install-WingetManuel

    Start-Sleep -Seconds 3
    Temizle-GeciciDosyalar

    if (Get-Command winget -ErrorAction SilentlyContinue) {
        Write-Host "İşlem Tamamlandı: Winget başarıyla kuruldu (manuel yedek yol)!" -ForegroundColor Green
        if ($ltsc) { Kur-WingetLTSCGuncellemeGorevi } # Manuel yolla kurulduysa ve LTSC ise görev ata
        return $true
    } else {
        Write-Host "İşlem Başarısız: Winget kurulamadı. Log: $Global:LogDosyasi" -ForegroundColor Red
        return $false
    }
}

# Betiğin indirileceği adres (yalnızca yerel dosya yoksa yedek olarak kullanılır)
$ScriptUrl = "https://raw.githubusercontent.com/mhmtsk44/bilgisayar-araci/refs/heads/main/Bilgisayar_Araci.ps1"

# Çalışan betiğin tam yolu (yönetici/terminal yükseltmesinde AYNI dosya yeniden çalışır)
$BetikYolu = $PSCommandPath
if ([string]::IsNullOrWhiteSpace($BetikYolu)) { $BetikYolu = $MyInvocation.MyCommand.Path }

# Yükseltme komutunu üret: yerel dosya varsa onu çalıştır, yoksa indir
function Get-BaslatmaKomutu {
    if (-not [string]::IsNullOrWhiteSpace($BetikYolu) -and (Test-Path $BetikYolu)) {
        # GÜVENLİ: incelenen yerel dosyanın kendisi çalışır, offline da çalışır
        return @{ Tip = "Dosya"; Deger = $BetikYolu }
    } else {
        # YEDEK: yerel dosya yoksa (örn. irm ile çağrıldıysa) uzaktan indir
        return @{ Tip = "Komut"; Deger = "irm '$ScriptUrl' | iex" }
    }
}

# AŞAMA 1: Yönetici değilsek -> yönetici olarak yeniden başlat
if (-not (Test-Admin)) {
    Write-Host "Yönetici izniyle yeniden başlatılıyor..." -ForegroundColor Yellow
    $bk = Get-BaslatmaKomutu
    try {
        if ($bk.Tip -eq "Dosya") {
            Start-Process powershell -ArgumentList "-ExecutionPolicy Bypass -File `"$($bk.Deger)`"" -Verb RunAs -ErrorAction Stop
        } else {
            # UZAKTAN (irm|iex) MOD: -NoExit eklendi ki hata olsa da pencere kapanmasın
            Start-Process powershell -ArgumentList "-NoExit -ExecutionPolicy Bypass -Command `"$($bk.Deger)`"" -Verb RunAs -ErrorAction Stop
        }
    } catch {
        Write-Host ""
        Write-Host "HATA: Yönetici izni verilmedi veya yükseltme başarısız oldu." -ForegroundColor Red
        Write-Host "Ayrıntı: $($_.Exception.Message)" -ForegroundColor DarkYellow
        Write-Host ""
        Read-Host "Kapatmak için Enter'a basın"
    }
    exit
}

# AŞAMA 1.5: Winget'i garantiye al (-Sessiz parametresiyle, ekranda yazı kalabalığı yapmaz)
$WingetVar = Install-Winget -Sessiz

# ===================== AŞAMA 2: WINDOWS TERMINAL'DE AÇ (güvenli, döngüsüz) =====================
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
                # Döngü bayrağını ÖNCEDEN bu pencerede ayarla; yeni pencere miras alır
                [Environment]::SetEnvironmentVariable("BILGISAYAR_ARACI_WT", "1", "Process")
                # -File ile çalıştır: yol boşluk içerse bile güvenli
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
            exit   # wt açıldı -> başlatıcı pencereyi kapat
        } catch {
            # wt açılamadı -> bu pencerede devam et
        }
    }
}

# ===================== TEMEL AYARLAR =====================
$ErrorActionPreference = "Continue"
$Host.UI.RawUI.WindowTitle = "Bilgisayar Aracı - Mehmet IŞIK"
try { [Console]::OutputEncoding = [System.Text.Encoding]::UTF8 } catch {}

if ($Host.Name -eq 'ConsoleHost') {
    try {
        $raw = $Host.UI.RawUI
        $max = $raw.MaxPhysicalWindowSize
        $genislik = [math]::Min(110, $max.Width)
        $yukseklik = [math]::Min(45, $max.Height)
        $raw.BufferSize = New-Object Management.Automation.Host.Size($genislik, 3000)
        $raw.WindowSize = New-Object Management.Automation.Host.Size($genislik, $yukseklik)
    } catch {}
}

try { $Host.UI.RawUI.BackgroundColor = "Black"; $Host.UI.RawUI.ForegroundColor = "Gray"; Clear-Host } catch {}

# ===================== MODERN TEMA / RENK PALETİ =====================
$Tema = @{
    Cerceve  = "DarkCyan"
    Vurgu    = "Cyan"
    Metin    = "Gray"
    Baslik   = "White"
    Basari   = "Green"
    Hata     = "Red"
    Soluk    = "DarkGray"
}
# ===================== MODERN ÇERÇEVE =====================
$BoxWidth = 78
function Show-Top    { Write-Host ("╔" + ("═" * $BoxWidth) + "╗") -ForegroundColor $Tema.Cerceve }
function Show-Bottom { Write-Host ("╚" + ("═" * $BoxWidth) + "╝") -ForegroundColor $Tema.Cerceve }
function Show-Divider{ Write-Host ("╟" + ("─" * $BoxWidth) + "╢") -ForegroundColor $Tema.Cerceve }
function Show-Bos    { Write-Host ("║" + (" " * $BoxWidth) + "║") -ForegroundColor $Tema.Cerceve }
function Show-Line {
    param([string]$Metin, [string]$Renk = $Tema.Metin)
    $temiz = $Metin
    if ($temiz.Length -gt $BoxWidth) { $temiz = $temiz.Substring(0, $BoxWidth) }
    $bosluk = [math]::Max(1, $BoxWidth - $temiz.Length)
    Write-Host "║" -ForegroundColor $Tema.Cerceve -NoNewline
    Write-Host (" " + $temiz + (" " * ($bosluk - 1))) -ForegroundColor $Renk -NoNewline
    Write-Host "║" -ForegroundColor $Tema.Cerceve
}

function Show-Header {
    param([string]$Baslik)
    Clear-Host
    Show-Top
    Show-Line "  💻 BİLGİSAYAR YÖNETİM ARACI" $Tema.Soluk
    Show-Line "  ──────────────────────────────" $Tema.Soluk  # İnce bir ayraç
    Show-Line "  ✨ $Baslik" $Tema.Vurgu
    Show-Bottom
    Write-Host ""
}

function Write-Result {
    param(
        $Basari,
        $Mesaj = ""
    )

    # --- AKILLI PARAMETRE ALGILAMA (iki çağrı stilini de destekler) ---
    #   DOĞRU:  Write-Result $true "mesaj"      (bool, string)
    #   ESKİ:   Write-Result $true "mesaj"       (string, bool)  ← otomatik düzeltilir
    # Eğer $Basari bool DEĞİL ama $Mesaj bool ise, parametreler ters gelmiştir → yer değiştir.
    if (($Basari -isnot [bool]) -and ($Mesaj -is [bool])) {
        $gecici = $Basari
        $Basari = $Mesaj
        $Mesaj  = $gecici
    }

    # --- Basari değerini güvenli şekilde Boolean'a çevir ---
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

    # $Mesaj'ı her zaman metne çevir (bool geldiyse bile güvenli)
    $mesajMetni = "$Mesaj"

    if ($durum) {
        Write-Host "  ✓  $mesajMetni" -ForegroundColor $Tema.Basari
    } else {
        Write-Host "  ✗  $mesajMetni" -ForegroundColor $Tema.Hata
    }
}

# ===================== WINGET BİLGİLENDİRME EKRANI =====================
function Show-WingetHelp {
    Show-Header "WINGET (PAKET YÖNETİCİSİ) BULUNAMADI"

    Write-Host "  Bilgisayarınızda Winget yüklü değil." -ForegroundColor $Tema.Hata
    Write-Host ""
    Write-Host "  Winget, Windows 10 (1809+) ve Windows 11'de varsayılan" -ForegroundColor $Tema.Metin
    Write-Host "  olarak gelen resmi bir paket yöneticisidir. Yüklü değilse" -ForegroundColor $Tema.Metin
    Write-Host "  aşağıdaki yöntemlerden biriyle kurabilirsiniz." -ForegroundColor $Tema.Metin
    Write-Host ("  " + ("-" * 74)) -ForegroundColor $Tema.Cerceve

    Write-Host "  YÖNTEM 1 — Microsoft Store (Önerilen)" -ForegroundColor $Tema.Vurgu
    Write-Host "   1) Başlat menüsünden 'Microsoft Store' uygulamasını açın." -ForegroundColor $Tema.Metin
    Write-Host "   2) Arama çubuğuna 'Uygulama Yükleyici' yazın." -ForegroundColor $Tema.Metin
    Write-Host "      (İngilizce: 'App Installer')" -ForegroundColor $Tema.Soluk
    Write-Host "   3) 'Uygulama Yükleyici'yi bulun ve Yükle/Güncelle deyin." -ForegroundColor $Tema.Metin
    Write-Host "   4) Kurulum bitince winget kullanıma hazır olur." -ForegroundColor $Tema.Metin
    Write-Host ""

    Write-Host "  YÖNTEM 2 — Geliştirici Modu üzerinden" -ForegroundColor $Tema.Vurgu
    Write-Host "   1) Başlat > 'Ayarlar' uygulamasını açın." -ForegroundColor $Tema.Metin
    Write-Host "   2) 'Gizlilik ve Güvenlik' > 'Geliştiriciler için' bölümüne gidin." -ForegroundColor $Tema.Metin
    Write-Host "      (Win 10: 'Güncelleme ve Güvenlik' > 'Geliştiriciler için')" -ForegroundColor $Tema.Soluk
    Write-Host "   3) 'Geliştirici Modu'nu açın." -ForegroundColor $Tema.Metin
    Write-Host "   4) Ardından Store'dan 'Uygulama Yükleyici'yi kurun." -ForegroundColor $Tema.Metin
    Write-Host ""

    Write-Host "  YÖNTEM 3 — Otomatik kurulum (bu araç)" -ForegroundColor $Tema.Vurgu
    Write-Host "   Bu araç açılışta winget'i otomatik kurmayı dener." -ForegroundColor $Tema.Metin
    Write-Host "   Başarısız olduysa internet bağlantınızı kontrol edip" -ForegroundColor $Tema.Metin
    Write-Host "   programı yeniden başlatın." -ForegroundColor $Tema.Metin
    Write-Host ""

    # Kullanıcıyı doğrudan Store'a yönlendirme seçeneği
    $ac = Read-Host "  Microsoft Store'da 'Uygulama Yükleyici' sayfasını açmak ister misiniz? (E/H)"
    if ($ac -eq "E" -or $ac -eq "e") {
        try {
            Start-Process "ms-windows-store://pdp/?productid=9NBLGGH4NNS1" -ErrorAction Stop
            Write-Result $true "Microsoft Store açıldı (Uygulama Yükleyici sayfası)."
        } catch {
            try {
                Start-Process "ms-windows-store://search/?query=Uygulama Yükleyici" -ErrorAction Stop
                Write-Result $true "Microsoft Store arama sayfası açıldı."
            } catch {
                Write-Result $false "Microsoft Store açılamadı: $($_.Exception.Message)"
            }
        }
    } else {
        Write-Result $true "Store açılmadı. Winget'i daha sonra kurabilirsiniz."
    }

    Write-Host ""
    Read-Host "  Devam etmek için Enter'a basın"
}

# ===================== WINGET KAYNAK GÜNCELLEME =====================
if ($WingetVar) {
    winget source update 2>$null | Out-Null
    if ($LASTEXITCODE -ne 0) {
        Write-Host "Uyari: winget kaynak guncellemesi tamamlanamadi." -ForegroundColor DarkYellow
    }
}

# ===================== YARDIMCI FONKSİYONLAR =====================
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

function Get-FreeSpaceMB {
    param([string]$SurucuHarfi = "C")
    try {
        $disk = Get-CimInstance Win32_LogicalDisk -Filter "DeviceID='${SurucuHarfi}:'"
        if ($disk) { return [math]::Round($disk.FreeSpace / 1MB, 2) }
        return 0
    } catch { return 0 }
}

function Select-Folder {
    param([string]$Aciklama = "Klasör seçin")
    Add-Type -AssemblyName System.Windows.Forms
    $dlg = New-Object System.Windows.Forms.FolderBrowserDialog
    $dlg.Description = $Aciklama
    if ($dlg.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) { return $dlg.SelectedPath }
    return $null
}

function Select-File {
    param([string]$Filtre = "JSON Dosyası (*.json)|*.json|Tüm Dosyalar (*.*)|*.*")
    Add-Type -AssemblyName System.Windows.Forms
    $dlg = New-Object System.Windows.Forms.OpenFileDialog
    $dlg.Filter = $Filtre
    if ($dlg.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) { return $dlg.FileName }
    return $null
}
function Invoke-YuzdeliIslem {
    param(
        [string]$Dosya,
        [string]$Argumanlar,
        [switch]$NullTemizle
    )

    $log = Join-Path $env:TEMP ("islem_" + [guid]::NewGuid().ToString("N") + ".log")
    "" | Out-File -FilePath $log -Encoding UTF8

    $islem = Start-Process -FilePath $Dosya `
             -ArgumentList $Argumanlar `
             -NoNewWindow -PassThru `
             -RedirectStandardOutput $log `
             -RedirectStandardError  ($log + ".err")

    $baslangic = Get-Date
    $sonYuzde  = 0
    $spinner   = @('|','/','-','\')
    $i = 0

    while (-not $islem.HasExited) {
        $yuzde = $sonYuzde
        try {
            if ($NullTemizle) {
                $ham = Get-Content $log -Raw -ErrorAction SilentlyContinue
                if ($ham) { $ham = $ham -replace "`0", "" }
            } else {
                $ham = (Get-Content $log -Tail 5 -ErrorAction SilentlyContinue) -join " "
            }

            if ($ham) {
                $m = [regex]::Matches($ham, '(\d{1,3})[.,]?\d*\s*%')
                if ($m.Count -gt 0) {
                    $son = $m[$m.Count - 1].Groups[1].Value
                    [int]$deger = 0
                    if ([int]::TryParse($son, [ref]$deger)) {
                        if ($deger -ge 0 -and $deger -le 100) { $yuzde = $deger }
                    }
                }
            }
        } catch {}
        if ($yuzde -lt $sonYuzde) { $yuzde = $sonYuzde }
        $sonYuzde = $yuzde

        $gecen = (Get-Date) - $baslangic
        $sure  = "{0:mm\:ss}" -f $gecen
        $kare  = $spinner[$i % $spinner.Count]

        $dolu  = [math]::Round($yuzde / 100 * 30)
        $cubuk = ("█" * $dolu) + ("░" * (30 - $dolu))

        Write-Host ("`r  [$kare] $cubuk  %$yuzde  •  $sure   ") -ForegroundColor Yellow -NoNewline
        Start-Sleep -Milliseconds 300
        $i++
    }

    # ===== KRİTİK DÜZELTME: İşlemin tam kapanmasını bekle =====
    $islem.WaitForExit()

    $cubukTam = "█" * 30
    Write-Host ("`r  [✓] $cubukTam  %100  •  tamamlandı        ") -ForegroundColor Green

    # ExitCode'u güvenli şekilde al (bazen -PassThru nesnesi geç dolar)
    $kod = $null
    try { $kod = $islem.ExitCode } catch { }
    if ($null -eq $kod) {
        # Yedek: process ID üzerinden tekrar dene
        try { $kod = (Get-Process -Id $islem.Id -ErrorAction SilentlyContinue).ExitCode } catch { }
    }
    if ($null -eq $kod) { $kod = 0 }  # okunamadıysa başarı say (işlem zaten bitti)

    Remove-Item $log, ($log + ".err") -Force -ErrorAction SilentlyContinue

    # SADECE sayıyı döndür (Write-Host çıktısı karışmasın diye)
    return [int]$kod
}
# ===================== UYGULAMA LİSTESİ (dizi — sıra %100 korunur) =====================

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
    @{ No = 16; Ad = "Alpemix (Uzak Bağlantı)";   Id = "ALPEMIX_OZEL" }
)

# ===================== UYGULAMA KURULUM =====================

function Install-App {
    param([string]$Ad, [string]$Id, [string]$Kaynak = "winget")

    if ($Id -eq "ALPEMIX_OZEL") {
        Install-Alpemix
        return
    }

    # winget yoksa erken çık
    if (-not $WingetVar) {
        Write-Result $false "$Ad kurulamadı: winget bulunamadı."
        return
    }

    Write-Host "  $Ad kuruluyor..." -ForegroundColor Yellow

    # Store uygulamaları için msstore kaynağı, diğerleri için varsayılan winget kaynağı
    if ($Kaynak -eq "msstore") {
        $argumanlar = "install --id $Id --source msstore --accept-package-agreements --accept-source-agreements"
    } else {
        $argumanlar = "install --id $Id --silent --accept-package-agreements --accept-source-agreements"
    }

    $sonuc = Start-Process winget -ArgumentList $argumanlar -Wait -PassThru -NoNewWindow
    switch ($sonuc.ExitCode) {
        0           { Write-Result $true "$Ad başarıyla kuruldu." }
        -1978335189 { Write-Result $true "$Ad zaten güncel / yüklü." }
        default     { Write-Result $false "$Ad kurulamadı (Kod: $($sonuc.ExitCode))." }
    }
}

# ===================== ALPEMIX ÖZEL İNDİRME (İMZA KONTROLLÜ) =====================
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
            Write-Result $false "İndirilen dosya bozuk görünüyor ($boyutKB KB). İptal edildi."
            Remove-Item $hedef -Force -ErrorAction SilentlyContinue
            return
        }
        Write-Result $true "Alpemix indirildi: $hedef ($boyutKB KB)"

        $imza = Get-AuthenticodeSignature $hedef
        $imzaGuvenli = $false
        switch ($imza.Status) {
            "Valid" {
                $imzaci = $imza.SignerCertificate.Subject
                Write-Result $true "Dijital imza GEÇERLİ."
                Write-Host ("       İmzalayan: " + $imzaci) -ForegroundColor DarkGray
                $imzaGuvenli = $true
            }
            "NotSigned" {
                Write-Result $false "UYARI: Dosya dijital olarak İMZALANMAMIŞ."
            }
            default {
                Write-Result $false ("UYARI: İmza durumu güvensiz: " + $imza.Status)
            }
        }

        if (-not $imzaGuvenli) {
            Write-Host ""
            Write-Host "  Bu dosyanın imzası doğrulanamadı. Yalnızca kaynağa" -ForegroundColor Yellow
            Write-Host "  güveniyorsanız çalıştırın." -ForegroundColor Yellow
        }
        $ac = Read-Host "  Alpemix şimdi çalıştırılsın mı? (E/H)"
        if ($ac -eq "E" -or $ac -eq "e") {
            Start-Process $hedef
            Write-Result $true "Alpemix başlatıldı."
        } else {
            Write-Result $true "Çalıştırma iptal edildi. Dosya masaüstünde duruyor."
        }
    } catch {
        Write-Result $false "Alpemix indirilemedi: $($_.Exception.Message)"
    }
}

# ===================== TÜM UYGULAMALARI GÜNCELLE =====================
function Update-AllApps {
    Show-Header "TÜM UYGULAMALARI GÜNCELLE"

    # Winget yoksa yardım ekranını göster (Kod 2'den)
    if (-not $WingetVar) {
        Show-WingetHelp
        return
    }

    Write-Host "  Sistemde yüklü tüm programlar güncelleniyor..." -ForegroundColor "Yellow"
    Write-Host "  (winget upgrade --all)" -ForegroundColor $Tema.Soluk
    Write-Host ""

    if (-not (Confirm-Islem "Tüm uygulamalar güncellensin mi?")) {
        Write-Result $false "İşlem iptal edildi."
        Read-Host "  Devam etmek için Enter'a basın"
        return
    }

    Write-Host ""
    Write-Host "  Güncelleme başlatılıyor, lütfen bekleyin..." -ForegroundColor $Tema.Vurgu
    Write-Host "  (Bu işlem birkaç dakika sürebilir.)" -ForegroundColor $Tema.Soluk
    Write-Host ""

    try {
        # KRİTİK: --disable-interactivity + --silent (Kod 1'den) → takılma/çift onay engellenir
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

    # ===== ÖZET KUTUSU (Kod 2'den) =====
    Write-Host ""
    Show-Top
    Show-Line "  GÜNCELLEME ÖZETİ" $Tema.Baslik
    Show-Divider
    if ($kod -eq 0 -or $null -eq $kod) {
        Show-Line "  ✓ Güncelleme işlemi tamamlandı." $Tema.Basari
    } else {
        Show-Line "  ⚠ Bazı paketler güncellenemedi (çıkış kodu: $kod)." $Tema.Hata
    }
    Show-Line "  Not: Güncellenecek paket yoksa 'her şey güncel' demektir." $Tema.Soluk
    Show-Bottom

    Write-Host ""
    Read-Host "  Devam etmek için Enter'a basın"
}
# ===================== SİSTEM FONKSİYONLARI =====================

function New-AdminFolders {
    Show-Header "YÖNETİM KLASÖRLERİ OLUŞTUR"
    Write-Host ""
    $onay = Read-Host "  Masaüstünde Admin ve GodMode klasörleri oluşturulsun mu? (E/H)"
    if ($onay -ne "E" -and $onay -ne "e") {
        Write-Result $false "İşlem iptal edildi."; Write-Host ""; Read-Host "  Devam etmek için Enter'a basın"; return
    }
    $masaustu = [Environment]::GetFolderPath("Desktop")
    try {
        $adminYol   = Join-Path $masaustu "Yönetim Araçları.{D20EA4E1-3957-11d2-A40B-0C5020524153}"
        $godmodeYol = Join-Path $masaustu "GodMode.{ED7BA470-8E54-465E-825C-99712043E01C}"
        if (-not (Test-Path $adminYol))   { New-Item -Path $adminYol -ItemType Directory -Force | Out-Null }
        if (-not (Test-Path $godmodeYol)) { New-Item -Path $godmodeYol -ItemType Directory -Force | Out-Null }
        Write-Result $true "Yönetim ve GodMode klasörleri masaüstünde oluşturuldu."
    } catch {
        Write-Result $false "Klasör oluşturulamadı: $($_.Exception.Message)"
    }
    Write-Host ""
    Read-Host "  Devam etmek için Enter'a basın"
}

function Show-SystemInfo {
    Show-Header "SİSTEM BİLGİLERİ"
    try {
        $os  = Get-CimInstance Win32_OperatingSystem
        $cs  = Get-CimInstance Win32_ComputerSystem
        $cpu = Get-CimInstance Win32_Processor | Select-Object -First 1
        
        # DOĞRU RAM HESABI (Hem fiziksel hem sanal makine uyumlu)
        $ram = [math]::Round($os.TotalVisibleMemorySize / 1024 / 1024)

        Write-Host ("  Bilgisayar : " + $cs.Name)          -ForegroundColor $Tema.Baslik
        Write-Host ("  İşletim S. : " + $os.Caption)       -ForegroundColor $Tema.Baslik
        Write-Host ("  Sürüm      : " + $os.Version)        -ForegroundColor $Tema.Metin
        Write-Host ("  İşlemci    : " + $cpu.Name.Trim())   -ForegroundColor $Tema.Metin
        Write-Host ("  RAM        : " + $ram + " GB")        -ForegroundColor $Tema.Metin
        Write-Host ("  Üretici    : " + $cs.Manufacturer)   -ForegroundColor $Tema.Metin
    } catch {
        Write-Host ("  Bilgi alınamadı: " + $_.Exception.Message) -ForegroundColor $Tema.Hata
    }
    Write-Host ""
    Read-Host "  Devam etmek için Enter'a basın"
}
function Show-DiskSummary {
    Show-Header "DİSK ÖZETİ"
    try {
        Get-CimInstance Win32_LogicalDisk -Filter "DriveType=3" | ForEach-Object {
            $toplam = [math]::Round($_.Size / 1GB, 1)
            $bos    = [math]::Round($_.FreeSpace / 1GB, 1)
            $dolu   = $toplam - $bos
            $yuzde  = if ($toplam -gt 0) { [math]::Round(($dolu / $toplam) * 100) } else { 0 }
            Write-Host ("  Sürücü " + $_.DeviceID + "  Toplam: $toplam GB  Boş: $bos GB  (%$yuzde dolu)") -ForegroundColor $Tema.Baslik
        }
    } catch {
        Write-Host ("  Disk bilgisi alınamadı.") -ForegroundColor $Tema.Hata
    }
    Write-Host ""
    Read-Host "  Devam etmek için Enter'a basın"
}

function Show-DiskHealth {
    Show-Header "DİSK SAĞLIĞI (SMART)"
    try {
        Get-PhysicalDisk | ForEach-Object {
            $durum = $_.HealthStatus
            $renk = if ($durum -eq "Healthy") { $Tema.Basari } else { $Tema.Hata }
            Write-Host ("  " + $_.FriendlyName + "  Durum: " + $durum) -ForegroundColor $renk
        }
    } catch {
        Write-Host ("  Disk sağlık bilgisi alınamadı.") -ForegroundColor $Tema.Hata
    }
    Write-Host ""
    Read-Host "  Devam etmek için Enter'a basın"
}
function Show-Startup {
    Show-Header "BAŞLANGIÇ PROGRAMLARI"

    # --- Kayıtlı başlangıç programlarını listele + say ---
    $sayac = 0
    try {
        Get-CimInstance Win32_StartupCommand | ForEach-Object {
            $sayac++
            Write-Host ("  " + $_.Name + "  ->  " + $_.Command) -ForegroundColor $Tema.Metin
        }
        if ($sayac -eq 0) {
            Write-Host "  Kayıtlı başlangıç programı bulunamadı." -ForegroundColor $Tema.Soluk
        } else {
            Write-Host ("  " + ("-" * 50)) -ForegroundColor $Tema.Cerceve
            Write-Host ("  Toplam $sayac başlangıç programı bulundu.") -ForegroundColor $Tema.Vurgu
        }
    } catch {
        Write-Host "  Başlangıç programları alınamadı." -ForegroundColor $Tema.Hata
    }

    Write-Host ""

    # --- E/H sorusu: Başlangıç ayar ekranını açmak ister mi? ---
    Write-Host "  Windows Başlangıç ayarlarını açmak ister misiniz? " -NoNewline -ForegroundColor $Tema.Metin
    Write-Host "(E/H)" -ForegroundColor $Tema.Vurgu
    $cevap = Read-Host "  Seçiminiz"

    if ($cevap -match '^[EeYy]') {
        Write-Host ""
        Write-Host "  Windows Başlangıç ayarları açılıyor..." -ForegroundColor $Tema.Metin
        try {
            Start-Process "ms-settings:startupapps" -ErrorAction Stop
            Write-Result $true "Ayarlar > Başlangıç sayfası açıldı."
        } catch {
            try {
                Start-Process "taskmgr.exe" -ArgumentList "/0 /startup" -ErrorAction Stop
                Write-Result $true "Görev Yöneticisi (Başlangıç sekmesi) açıldı."
            } catch {
                Write-Result $false "Başlangıç ayarları açılamadı: $($_.Exception.Message)"
            }
        }
    } else {
        Write-Host ""
        Write-Result $true "Başlangıç ayarları açılmadı. Ana menüye dönülüyor."
    }

    Read-Host "`n  Devam etmek için Enter'a basın"
}

function Start-WindowsUpdate {
    Show-Header "WINDOWS GÜNCELLEMELERİ"
    Write-Host ""
    $onay = Read-Host "  Windows güncellemeleri aranıp kurulsun mu? (E/H)"
    if ($onay -ne "E" -and $onay -ne "e") {
        Write-Result $false "İşlem iptal edildi."; Write-Host ""; Read-Host "  Devam etmek için Enter'a basın"; return
    }
    try {
        if (-not (Get-Module -ListAvailable -Name PSWindowsUpdate)) {
            Write-Progress -Activity "Windows Update" -Status "PSWindowsUpdate modülü kuruluyor..." -PercentComplete 10
            Write-Host "  [1/3] PSWindowsUpdate modülü kuruluyor..." -ForegroundColor Yellow
            Install-PackageProvider -Name NuGet -Force -ErrorAction SilentlyContinue | Out-Null
            Install-Module PSWindowsUpdate -Force -Scope CurrentUser -Confirm:$false -ErrorAction SilentlyContinue
        } else {
            Write-Host "  [1/3] PSWindowsUpdate modülü hazır." -ForegroundColor DarkGray
        }

        Write-Progress -Activity "Windows Update" -Status "Modül yükleniyor..." -PercentComplete 40
        Import-Module PSWindowsUpdate -ErrorAction SilentlyContinue

        Write-Progress -Activity "Windows Update" -Status "Güncellemeler aranıyor ve kuruluyor..." -PercentComplete 70
        Write-Host "  [2/3] Güncellemeler aranıyor..." -ForegroundColor Yellow
        Write-Host "  [3/3] Bulunanlar kuruluyor (bu işlem uzun sürebilir)..." -ForegroundColor Yellow
        Write-Host ""

        # -Verbose ile her güncellemenin durumu ekrana yansır
        Get-WindowsUpdate -AcceptAll -Install -IgnoreReboot -Verbose

        Write-Progress -Activity "Windows Update" -Completed
        Write-Host ""
        Write-Result $true "Windows güncelleme işlemi tamamlandı."
    } catch {
        Write-Progress -Activity "Windows Update" -Completed
        Write-Result $false "Güncelleme yapılamadı: $($_.Exception.Message)"
    }
    Write-Host ""
    Read-Host "  Devam etmek için Enter'a basın"
}

function Reset-Network {
    Show-Header "AĞ SIFIRLAMA"
    Write-Host ""
if (-not (Confirm-Islem "Ağ ayarları sıfırlanacak (DNS, Winsock, IP). Emin misiniz?")) {
    Write-Result $false "İşlem iptal edildi."
    Write-Host ""; Read-Host "  Devam etmek için Enter'a basın"; return
}

    try {
        ipconfig /flushdns | Out-Null
        netsh winsock reset | Out-Null
        netsh int ip reset | Out-Null
        Write-Result $true "Ağ ayarları sıfırlandı. Bilgisayarı yeniden başlatın."
    } catch {
        Write-Result $false "Ağ sıfırlanamadı: $($_.Exception.Message)"
    }
    Write-Host ""
    Read-Host "  Devam etmek için Enter'a basın"
}

function New-RestorePoint {
    Show-Header "SİSTEM GERİ YÜKLEME NOKTASI"
    Write-Host ""
    $onay = Read-Host "  Sistem geri yükleme noktası oluşturulsun mu? (E/H)"
    if ($onay -ne "E" -and $onay -ne "e") {
        Write-Result $false "İşlem iptal edildi."; Write-Host ""; Read-Host "  Devam etmek için Enter'a basın"; return
    }

try {
        Enable-ComputerRestore -Drive "C:\" -ErrorAction SilentlyContinue
        Checkpoint-Computer -Description "Bilgisayar Araci - $(Get-Date -Format 'yyyy-MM-dd HH:mm')" -RestorePointType "MODIFY_SETTINGS" -ErrorAction Stop
        Write-Result $true "Geri yükleme noktası oluşturuldu."
    } catch {
        Write-Result $false "Geri yükleme noktası oluşturulamadı: $($_.Exception.Message)"
    }

    Write-Host ""
    Read-Host "  Devam etmek için Enter'a basın"
}

function Clear-PrintQueue {
    Show-Header "YAZICI KUYRUĞUNU TEMİZLE"
    Write-Host ""
    $onay = Read-Host "  Yazıcı kuyruğu temizlenecek. Onaylıyor musunuz? (E/H)"
    if ($onay -ne "E" -and $onay -ne "e") {
        Write-Result $false "İşlem iptal edildi."; Write-Host ""; Read-Host "  Devam etmek için Enter'a basın"; return
    }
    try {
        Stop-Service -Name Spooler -Force -ErrorAction SilentlyContinue
        Remove-Item "$env:SystemRoot\System32\spool\PRINTERS\*" -Force -ErrorAction SilentlyContinue
        Start-Service -Name Spooler -ErrorAction SilentlyContinue
        Write-Result $true "Yazıcı kuyruğu temizlendi."
    } catch {
        Write-Result $false "Yazıcı kuyruğu temizlenemedi: $($_.Exception.Message)"
    }
    Write-Host ""
    Read-Host "  Devam etmek için Enter'a basın"
}

function Show-HealthSummary {
    Show-Header "SİSTEM SAĞLIK ÖZETİ"
    try {
        $os  = Get-CimInstance Win32_OperatingSystem
        $cs  = Get-CimInstance Win32_ComputerSystem
        
        # DOĞRU RAM HESABI
        $ram = [math]::Round($os.TotalVisibleMemorySize / 1024 / 1024)
        $bosRam = [math]::Round($os.FreePhysicalMemory / 1024 / 1024, 1)
        
        $cDisk = Get-CimInstance Win32_LogicalDisk -Filter "DeviceID='C:'"
        $cBos = [math]::Round($cDisk.FreeSpace / 1GB, 1)
        $cTop = [math]::Round($cDisk.Size / 1GB, 1)
        $uptime = (Get-Date) - $os.LastBootUpTime

        Write-Host ("  RAM        : " + $ram + " GB  (Boş: " + $bosRam + " GB)") -ForegroundColor $Tema.Baslik
        Write-Host ("  C: Disk    : " + $cTop + " GB  (Boş: " + $cBos + " GB)") -ForegroundColor $Tema.Baslik
        Write-Host ("  Çalışma S. : " + $uptime.Days + " gün " + $uptime.Hours + " saat") -ForegroundColor $Tema.Metin

        $cYuzde = if ($cTop -gt 0) { [math]::Round((($cTop - $cBos) / $cTop) * 100) } else { 0 }
        Write-Host ("  " + ("-" * 50)) -ForegroundColor $Tema.Cerceve
        if ($cYuzde -gt 90) { Write-Host "  ⚠ C: sürücüsü neredeyse dolu!" -ForegroundColor $Tema.Hata }
        elseif ($cYuzde -gt 75) { Write-Host "  ⚠ C: sürücüsünde yer azalıyor." -ForegroundColor Yellow }
        else { Write-Host "  ✓ Disk durumu iyi." -ForegroundColor $Tema.Basari }

        if ($bosRam -lt 1) { Write-Host "  ⚠ Boş RAM düşük!" -ForegroundColor $Tema.Hata }
        else { Write-Host "  ✓ RAM durumu iyi." -ForegroundColor $Tema.Basari }
    } catch {
        Write-Host ("  Sağlık özeti alınamadı: " + $_.Exception.Message) -ForegroundColor $Tema.Hata
    }
    Write-Host ""
    Read-Host "  Devam etmek için Enter'a basın"
}

# ===================== GÜVENLİK: TEHLİKELİ YOL KONTROLÜ (SON HAL v2) =====================
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
# ===================== TEMİZLİK FONKSİYONLARI =====================
function Clean-Temp {
    Show-Header "GEÇİCİ DOSYALARI TEMİZLE"

    $hedefler = @(
        @{ Ad = "Kullanıcı TEMP";        Yol = $env:TEMP }
        @{ Ad = "Windows TEMP";          Yol = "$env:SystemRoot\Temp" }
        @{ Ad = "Yerel AppData TEMP";    Yol = "$env:LOCALAPPDATA\Temp" }
        @{ Ad = "Prefetch";              Yol = "$env:SystemRoot\Prefetch" }
        @{ Ad = "Thumbnail Önbellek";    Yol = "$env:LOCALAPPDATA\Microsoft\Windows\Explorer" }
        @{ Ad = "Son Kullanılanlar";     Yol = "$env:APPDATA\Microsoft\Windows\Recent" }
    )

    if (-not (Confirm-Islem "Geçici dosyalar temizlensin mi?")) {
        Write-Result $false "İşlem iptal edildi."
        Read-Host "  Devam etmek için Enter'a basın"
        return
    }

    Write-Host ""
    $toplamKazanc = 0.0
    $toplamSilinen = 0
    $toplamHata    = 0

    foreach ($k in $hedefler) {
        if ([string]::IsNullOrWhiteSpace($k.Yol) -or -not (Test-Path $k.Yol)) {
            Write-Host ("  ▸ " + $k.Ad + " — bulunamadı, atlandı.") -ForegroundColor $Tema.Soluk
            continue
        }

        if (-not (Test-GuvenliYol $k.Yol)) {
            Write-Host ("  ⚠ " + $k.Ad + " — GÜVENLİK nedeniyle atlandı.") -ForegroundColor Yellow
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
        Write-Host ("  ✓ " + $k.Ad.PadRight(22) + " temizlendi — $hedefSilinen dosya, $hedefKazancYuvarli MB") -ForegroundColor $Tema.Basari

        $toplamKazanc  += $hedefKazanc
        $toplamSilinen += $hedefSilinen
        $toplamHata    += $hedefHata
    }

    $kazancYuvarli = [math]::Round($toplamKazanc, 2)

    # ===== ÖZET KUTUSU =====
    Write-Host ""
    Show-Top
    Show-Line "  TEMİZLİK ÖZETİ" $Tema.Baslik
    Show-Divider
    Show-Line ("  Silinen dosya    : " + $toplamSilinen) $Tema.Metin
    Show-Line ("  Kazanılan alan   : " + $kazancYuvarli + " MB") $Tema.Basari
    if ($toplamHata -gt 0) {
        Show-Line ("  Atlanan (kilitli): " + $toplamHata + " dosya (normal)") $Tema.Soluk
    }
    Show-Bottom

    Write-Host ""
    Write-Host "  Not: Prefetch silindiği için ilk açılışlar biraz yavaş" -ForegroundColor $Tema.Soluk
    Write-Host "  olabilir, sistem birkaç açılışta yeniden oluşturur." -ForegroundColor $Tema.Soluk

    Write-Host ""
    Read-Host "  Devam etmek için Enter'a basın"
}
function Clean-Logs {
    Show-Header "OLAY GÜNLÜKLERİNİ TEMİZLE"

    Write-Host "  Windows olay günlükleri temizleniyor..." -ForegroundColor "Yellow"
    Write-Host "  (Bu işlem birkaç dakika sürebilir, lütfen bekleyin)" -ForegroundColor $Tema.Soluk
    Write-Host ""

    if (-not (Confirm-Islem "Tüm olay günlükleri temizlensin mi?")) {
        Write-Result $false "İşlem iptal edildi."
        Read-Host "  Devam etmek için Enter'a basın"
        return
    }

    Write-Host ""

    try {
        $loglar = @(wevtutil el 2>$null)
        $toplam = $loglar.Count

        if ($toplam -eq 0) {
            Write-Result $false "Temizlenecek olay günlüğü bulunamadı."
            Write-Host ""
            Read-Host "  Devam etmek için Enter'a basın"
            return
        }

        $sayac    = 0
        $basarili = 0

        foreach ($log in $loglar) {
            $sayac++

            $yuzde = [math]::Round(($sayac / $toplam) * 100)
            $dolu  = [math]::Round($yuzde / 100 * 30)
            $cubuk = ("█" * $dolu) + ("░" * (30 - $dolu))
            Write-Host ("`r  [$cubuk]  %$yuzde  ($sayac/$toplam)   ") -ForegroundColor Yellow -NoNewline

            wevtutil cl "$log" 2>$null
            if ($LASTEXITCODE -eq 0) { $basarili++ }
        }

        Write-Host ("`r  [" + ("█" * 30) + "]  %100  tamamlandı            ") -ForegroundColor Green
        Write-Host ""

        Write-Result $true "$basarili / $toplam olay günlüğü temizlendi."
        if ($basarili -lt $toplam) {
            Write-Host "  Not: Bazı korumalı günlükler temizlenemez (normaldir)." -ForegroundColor $Tema.Soluk
        }
    } catch {
        Write-Result $false ("Günlükler temizlenirken hata: " + $_.Exception.Message)
    }

    Write-Host ""
    Read-Host "  Devam etmek için Enter'a basın"
}
function Clean-WinUpdate {
    Show-Header "WINDOWS UPDATE ÖNBELLEĞİNİ TEMİZLE"
    try {
        Stop-Service -Name wuauserv -Force -ErrorAction SilentlyContinue
        Remove-Item "$env:SystemRoot\SoftwareDistribution\Download\*" -Recurse -Force -ErrorAction SilentlyContinue
        Start-Service -Name wuauserv -ErrorAction SilentlyContinue
        Write-Result $true "Windows Update önbelleği temizlendi."
    } catch {
        Write-Result $false "Önbellek temizlenemedi: $($_.Exception.Message)"
    }
    Write-Host ""
    Read-Host "  Devam etmek için Enter'a basın"
}

function Clean-RecycleBin {
    Show-Header "GERİ DÖNÜŞÜM KUTUSU TEMİZLE"
    Write-Host ""

    try {
        Clear-RecycleBin -Force -ErrorAction Stop
        Write-Host "  ✓  Geri dönüşüm kutusu temizlendi" -ForegroundColor $Tema.Basari
    }
    catch {
        if ($_.Exception.Message -match "belirtilen yolu bulamıyor" -or
            $_.Exception.Message -match "cannot find the path" -or
            $_.Exception.Message -match "Recycle Bin.*empty" -or
            $_.Exception.Message -match "boş") {
            Write-Host "  ✓  Geri dönüşüm kutusu temizlendi" -ForegroundColor $Tema.Basari
        }
        else {
            Write-Host "  ✗  Geri dönüşüm kutusu boşaltılamadı: $($_.Exception.Message)" -ForegroundColor $Tema.Hata
        }
    }

    Write-Host ""
    Read-Host "  Devam etmek için Enter'a basın"
}
function Clean-Disk {
    Show-Header "DİSK TEMİZLEME ARACI (cleanmgr)"
    try {
        Start-Process cleanmgr -ArgumentList "/sagerun:1" -Wait
        Write-Result $true "Disk Temizleme aracı çalıştırıldı."
    } catch {
        Write-Result $false "Disk Temizleme çalıştırılamadı: $($_.Exception.Message)"
    }
    Write-Host ""
    Read-Host "  Devam etmek için Enter'a basın"
}
function Clean-GpuLeftovers {
    Show-Header "EKRAN KARTI SÜRÜCÜ ARTIKLARINI TEMİZLE"

    Write-Host "  Bu işlem AMD / NVIDIA / Intel kurulum artıklarını temizler." -ForegroundColor $Tema.Metin
    Write-Host "  (Yüklü sürücüler etkilenmez, yalnızca kurulum klasörleri)" -ForegroundColor $Tema.Soluk
    Write-Host ""

    if (-not (Confirm-Islem "Sürücü kurulum artıkları temizlensin mi?")) {
        Write-Result $false "İşlem iptal edildi."
        Read-Host "  Devam etmek için Enter'a basın"
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
            Write-Result $true ((Split-Path $h -Leaf) + " klasörü yok, atlandı.")
            continue
        }

        $tam = (Resolve-Path $h -ErrorAction SilentlyContinue).Path
        if ($tam -and ($yasakli -contains $tam.TrimEnd('\'))) {
            Write-Result $false ("GÜVENLİK nedeniyle atlandı: " + $tam)
            continue
        }

        $ad = Split-Path $h -Leaf
        $oncesi = Get-FolderSizeMB $h
        try {
            Remove-Item -Path $h -Recurse -Force -ErrorAction SilentlyContinue
            $kazanc += $oncesi
            Write-Result $true ($ad + " kurulum artıkları temizlendi.")
        } catch {
            Write-Result $false ($ad + " temizlenirken hata: " + $_.Exception.Message)
        }
    }

    Write-Host ""
    Write-Host ("  " + ("-" * 50)) -ForegroundColor $Tema.Cerceve
    Write-Result $true ("Toplam temizlenen alan: $kazanc MB")

    Write-Host ""
    Read-Host "  Devam etmek için Enter'a basın"
}
function Repair-SystemFiles {
    Show-Header "SİSTEM DOSYALARINI ONAR (DISM + SFC)"

    Write-Host "  Sistem dosyaları taranıp onarılıyor..." -ForegroundColor "Yellow"
    Write-Host "  (DISM + SFC — bu işlem 10-20 dakika sürebilir)" -ForegroundColor $Tema.Soluk
    Write-Host ""

    if (-not (Confirm-Islem "Sistem dosyası onarımı başlatılsın mı?")) {
        Write-Result $false "İşlem iptal edildi."
        Read-Host "  Devam etmek için Enter'a basın"
        return
    }

    Write-Host ""

    # ===== 1) DISM RestoreHealth =====
    Write-Host "  [1/2] DISM /RestoreHealth çalışıyor..." -ForegroundColor $Tema.Vurgu
    $dismKod = Invoke-YuzdeliIslem -Dosya "DISM.exe" `
                -Argumanlar "/Online /Cleanup-Image /RestoreHealth" -NullTemizle
    if ($dismKod -eq 0) {
        Write-Result $true "DISM onarımı tamamlandı."
    } else {
        Write-Result $false "DISM hata koduyla bitti: $dismKod"
    }

    Write-Host ""

    # ===== 2) SFC ScanNow =====
    Write-Host "  [2/2] SFC /ScanNow çalışıyor..." -ForegroundColor $Tema.Vurgu
    $sfcKod = Invoke-YuzdeliIslem -Dosya "sfc.exe" -Argumanlar "/scannow" -NullTemizle
    if ($sfcKod -eq 0) {
        Write-Result $true "SFC taraması tamamlandı."
    } else {
        Write-Result $false "SFC hata koduyla bitti: $sfcKod"
    }

    Write-Host ""
    Write-Host "  Not: Onarım sonrası bilgisayarı yeniden başlatmanız önerilir." -ForegroundColor $Tema.Soluk

    Write-Host ""
    Read-Host "  Devam etmek için Enter'a basın"
}
# ==================================================================================
#  HİBRİT PROTECT-USB  (v3.2)
# ==================================================================================
function Protect-USB {
    Show-Header "USB DİSK KORUMA / BİÇİMLENDİRME (HİBRİT v3.2)"

    $diskler = Get-Disk | Where-Object { $_.BusType -eq 'USB' }
    if (-not $diskler) {
        Write-Host "  Bağlı USB disk bulunamadı." -ForegroundColor $Tema.Hata
        Write-Host ""
        Read-Host "  Devam etmek için Enter'a basın"
        return
    }

    Write-Host "  Bağlı USB diskler:" -ForegroundColor $Tema.Vurgu
    Write-Host ""
    foreach ($d in $diskler) {
        $boyutGB = [math]::Round($d.Size / 1GB, 1)
        Write-Host ("   Disk {0}  |  {1}  |  {2} GB" -f $d.Number, $d.FriendlyName, $boyutGB) -ForegroundColor $Tema.Metin
    }
    Write-Host ""

    $secim = Read-Host "  İşlem yapılacak disk numarasını girin (iptal için q)"
    if ($secim -eq 'q' -or [string]::IsNullOrWhiteSpace($secim)) {
        Write-Result $false "İşlem iptal edildi."
        Read-Host "  Devam etmek için Enter'a basın"
        return
    }

    $diskNo = 0
    if (-not [int]::TryParse($secim, [ref]$diskNo)) {
        Write-Result $false "Geçersiz disk numarası."
        Read-Host "  Devam etmek için Enter'a basın"
        return
    }

    $hedefDisk = $diskler | Where-Object { $_.Number -eq $diskNo }
    if (-not $hedefDisk) {
        Write-Result $false "Belirtilen numarada USB disk bulunamadı."
        Read-Host "  Devam etmek için Enter'a basın"
        return
    }

    if ($hedefDisk.BusType -ne 'USB') {
        Write-Host "  ⚠ UYARI: Bu disk USB değil! İşlem güvenlik nedeniyle durduruldu." -ForegroundColor $Tema.Hata
        Write-Host ""
        Read-Host "  Devam etmek için Enter'a basın"
        return
    }

    $diskBoyutGB = [math]::Round($hedefDisk.Size / 1GB, 1)
    if ($diskBoyutGB -gt 512) {
        Write-Host "  ⚠ UYARI: Disk çok büyük ($diskBoyutGB GB). Harici HDD olabilir." -ForegroundColor $Tema.Hata
        if (-not (Confirm-Islem "Yine de devam edilsin mi?")) {
            Write-Result $false "İşlem iptal edildi."
            Read-Host "  Devam etmek için Enter'a basın"
            return
        }
    }

    Write-Host ""
    Write-Host ("  Seçilen: Disk {0} - {1} ({2} GB)" -f $hedefDisk.Number, $hedefDisk.FriendlyName, $diskBoyutGB) -ForegroundColor $Tema.Vurgu
    Write-Host ""
    Write-Host "  Ne yapmak istersiniz?" -ForegroundColor $Tema.Baslik
    Write-Host "   1) GÜVENLİ HALE GETİR + biçimlendir (TÜM VERİ SİLİNİR, autorun koruması eklenir)" -ForegroundColor $Tema.Metin
    Write-Host "   2) Bölümleri listele (salt okuma, güvenli)" -ForegroundColor $Tema.Metin
    Write-Host "   q) İptal" -ForegroundColor $Tema.Soluk
    Write-Host ""

    $islemTipi = Read-Host "  Seçiminiz"

    switch ($islemTipi) {
        "1" {
            Write-Host ""
            Write-Host ("  " + ("═" * 50)) -ForegroundColor $Tema.Hata
            Write-Host "  ⚠ KALICI VERİ SİLME + KORUMA İŞLEMİ" -ForegroundColor $Tema.Hata
            Write-Host ("   Disk   : {0}" -f $hedefDisk.FriendlyName) -ForegroundColor $Tema.Metin
            Write-Host ("   Boyut  : {0} GB" -f $diskBoyutGB) -ForegroundColor $Tema.Metin
            Write-Host "   Silinecek: Diskteki TÜM bölümler ve veriler" -ForegroundColor $Tema.Metin
            Write-Host ("  " + ("═" * 50)) -ForegroundColor $Tema.Hata
            Write-Host ""

            $onay = Read-Host "  Onaylamak için diskin adını yazın ('$($hedefDisk.FriendlyName)')"
            if ($onay -ne $hedefDisk.FriendlyName) {
                Write-Result $false "Disk adı eşleşmedi. İşlem güvenlik nedeniyle iptal edildi."
                Read-Host "  Devam etmek için Enter'a basın"
                return
            }

            try {
                Write-Host ""
                Write-Host "  İşlem yapılıyor, lütfen bekleyin..." -ForegroundColor $Tema.Vurgu

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
                    Write-Result $false "Sürücü harfi atanamadı. Diski çıkarıp yeniden takmayı deneyin veya manuel harf atayın."
                    Read-Host "  Devam etmek için Enter'a basın"
                    return
                }

                Format-Volume -Partition $yeniBolum -FileSystem NTFS -NewFileSystemLabel $eskiEtiket -Confirm:$false -ErrorAction Stop | Out-Null
                $harf = $yeniBolum.DriveLetter + ":"

                $guvenliKlasor = "$harf\GüvenliDosya"
                New-Item -Path $guvenliKlasor -ItemType Directory -Force | Out-Null

                $autorunYolu = "$harf\autorun.inf"
                try {
                    New-Item -Path $autorunYolu -ItemType Directory -Force -ErrorAction Stop | Out-Null
                    attrib +h +s $autorunYolu                                                  
                    icacls $autorunYolu /deny "*S-1-1-0:(OI)(CI)(F)" /Q | Out-Null   
                } catch {
                    Write-Host ("  ⚠ Autorun koruması uygulanamadı: " + $_.Exception.Message) -ForegroundColor $Tema.Hata
                }

                icacls "$harf\" /deny "*S-1-1-0:(AD,WD)" /Q | Out-Null
                icacls $guvenliKlasor /grant "*S-1-1-0:(OI)(CI)(F)" /Q | Out-Null

                Write-Host ""
                Write-Result $true ("İşlem tamamlandı! Sürücü: " + $harf + "  |  Etiket: " + $eskiEtiket)
                Write-Host "  Mükemmel! Ana dizine doğrudan virüs/dosya atılamaz, ama sürücü normal açılır." -ForegroundColor $Tema.Basari
                Write-Host ("  Tüm dosyalarınızı '{0}\GüvenliDosya' içine atmalısınız." -f $harf) -ForegroundColor $Tema.Basari
            } catch {
                Write-Result $false ("İşlem başarısız: " + $_.Exception.Message)
            }

            Write-Host ""
            Read-Host "  Devam etmek için Enter'a basın"
        }

        "2" {
            Write-Host ""
            Write-Host "  Disk üzerindeki bölümler:" -ForegroundColor $Tema.Vurgu
            Write-Host ""
            try {
                $bolumler = Get-Partition -DiskNumber $diskNo -ErrorAction Stop
                foreach ($b in $bolumler) {
                    $bBoyutGB = [math]::Round($b.Size / 1GB, 2)
                    $harf = if ($b.DriveLetter) { $b.DriveLetter + ":" } else { "(harf yok)" }
                    Write-Host ("   Bölüm {0}  |  {1}  |  {2} GB" -f $b.PartitionNumber, $harf, $bBoyutGB) -ForegroundColor $Tema.Metin
                }
            } catch {
                Write-Result $false ("Bölümler listelenemedi: " + $_.Exception.Message)
            }

            Write-Host ""
            Read-Host "  Devam etmek için Enter'a basın"
        }

        default {
            Write-Result $false "İşlem iptal edildi."
            Read-Host "  Devam etmek için Enter'a basın"
        }
    }
}
# ===================== DİSK KONTROL VE ONARIM (chkdsk) =====================
function Repair-Disk {
    Show-Header "SİSTEM VE DİSK ONARIMI"

    Write-Host "  Yapılacak işlemi seçin:" -ForegroundColor $Tema.Metin
    Write-Host ""
    Write-Host "   [1] Sistem dosyası onarımı (SFC /scannow)" -ForegroundColor $Tema.Metin
    Write-Host "   [2] Sistem görüntüsü onarımı (DISM RestoreHealth)" -ForegroundColor $Tema.Metin
    Write-Host "   [3] Disk kontrolü (CHKDSK - disk seçmeli)" -ForegroundColor $Tema.Metin
    Write-Host "   [4] Sistem onarımı (SFC + DISM birlikte)" -ForegroundColor $Tema.Metin
    Write-Host "   [0] Geri" -ForegroundColor $Tema.Soluk
    Write-Host ""

    $girdi = Read-Host "  Seçiminiz"

    [int]$anaSecim = 0
    if (-not [int]::TryParse($girdi, [ref]$anaSecim)) {
        Write-Result $false "Geçersiz giriş. Lütfen bir sayı girin."
        Read-Host "  Devam etmek için Enter'a basın"
        return
    }

    switch ($anaSecim) {
        0 { return }

        1 {
            Write-Host ""
            Write-Host "  SFC taraması başlatılıyor..." -ForegroundColor $Tema.Metin
            sfc /scannow
            Write-Host ""
            Read-Host "  Devam etmek için Enter'a basın"
        }

        2 {
            Write-Host ""
            Write-Host "  DISM onarımı başlatılıyor..." -ForegroundColor $Tema.Metin
            DISM /Online /Cleanup-Image /RestoreHealth
            Write-Host ""
            Read-Host "  Devam etmek için Enter'a basın"
        }

        4 {
            Write-Host ""
            Write-Host "  SFC + DISM sırayla çalıştırılıyor..." -ForegroundColor $Tema.Metin
            sfc /scannow
            DISM /Online /Cleanup-Image /RestoreHealth
            Write-Host ""
            Read-Host "  Devam etmek için Enter'a basın"
        }

        3 {
            Invoke-ChkdskSecmeli
        }

        default {
            Write-Result $false "Geçersiz seçim: $anaSecim"
            Read-Host "  Devam etmek için Enter'a basın"
        }
    }
}
function Invoke-ChkdskSecmeli {
    Show-Header "DİSK KONTROLÜ (CHKDSK)"

    try {
        $diskler = Get-Disk | Sort-Object Number -ErrorAction Stop
    } catch {
        Write-Result $false "Disk bilgisi alınamadı: $($_.Exception.Message)"
        Write-Host ""; Read-Host "  Devam etmek için Enter'a basın"; return
    }

    if (-not $diskler) {
        Write-Result $false "Hiç disk bulunamadı."
        Write-Host ""; Read-Host "  Devam etmek için Enter'a basın"; return
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
            $sistemMi = if ($disk.IsBoot -or $disk.IsSystem) { ' [SİSTEM DİSKİ]' } else { '' }

            Write-Host ("  [Disk $($disk.Number)] $model") -ForegroundColor $Tema.Baslik
            Write-Host ("     $busType - $boyutGB GB$sistemMi") -ForegroundColor $Tema.Soluk

            $bolumler = Get-Partition -DiskNumber $disk.Number -ErrorAction SilentlyContinue |
                        Where-Object { $_.DriveLetter }

            if (-not $bolumler) {
                Write-Host "        (harflendirilmiş bölüm yok)" -ForegroundColor $Tema.Soluk
                Write-Host ""
                continue
            }

            foreach ($bolum in $bolumler) {
                $harf     = $bolum.DriveLetter
                $vol      = Get-Volume -DriveLetter $harf -ErrorAction SilentlyContinue
                $etiket   = if ($vol.FileSystemLabel) { $vol.FileSystemLabel } else { 'etiket yok' }
                $fs       = if ($vol.FileSystem) { $vol.FileSystem } else { '?' }
                $bolBoyut = if ($vol.Size) { [math]::Round($vol.Size / 1GB, 2) } else { 0 }
                $sysMi    = if ($harf -eq $env:SystemDrive.TrimEnd(':')) { ' [SİSTEM]' } else { '' }

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
            Write-Result $false "Taranabilecek harflendirilmiş bölüm yok."
            Write-Host ""; Read-Host "  Devam etmek için Enter'a basın"; return
        }

        $girdiSecim = Read-Host "  Taramak istediğin bölüm numarası (İptal için 0)"

        [int]$secim = 0
        if (-not [int]::TryParse($girdiSecim, [ref]$secim)) {
            Write-Result $false "Geçersiz giriş. Sayı girmelisiniz. Tekrar deneyin."
            continue   
        }
        if ($secim -eq 0) {
            Write-Result $false "İşlem iptal edildi."
            Write-Host ""; Read-Host "  Devam etmek için Enter'a basın"; return
        }

        $aday = $harfListesi | Where-Object { $_.No -eq $secim }
        if (-not $aday) {
            Write-Result $false "Geçersiz seçim ($secim). Listeden bir numara seçin."
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
        Write-Host "  ▸ Seçilen: $secimAdi" -ForegroundColor $Tema.Vurgu
        Write-Host ""

        $dogruMu = Read-Host "  Bu bölüm doğru mu? (E = evet devam / H = hayır tekrar seç)"
        if ($dogruMu.ToUpper() -ne 'E') {
            Write-Host "  Tekrar seçim yapabilirsiniz..." -ForegroundColor $Tema.Soluk
            continue   
        }

        $secilen = $aday   
    }

    $harf = $secilen.Harf
    $fs   = $secilen.FS

    if ($fs -in @('exFAT', 'FAT', 'FAT32')) {
        Write-Host ""
        Write-Host "  UYARI: $secimAdi" -ForegroundColor Yellow
        Write-Host "  $fs formatında chkdsk sınırlı çalışır (/R yok)." -ForegroundColor $Tema.Soluk
        Write-Host ""
    }

    Write-Host "  Tarama modu seç:" -ForegroundColor $Tema.Baslik
    Write-Host "     1) Hızlı  (/F /X) - hataları düzelt" -ForegroundColor $Tema.Metin
    Write-Host "     2) Derin  (/R /X) - bozuk sektör (çok uzun)" -ForegroundColor $Tema.Metin
    Write-Host ""
    $modGirdi = Read-Host "  Mod (1/2)"

    if ($fs -in @('exFAT', 'FAT', 'FAT32') -and $modGirdi -eq '2') {
        Write-Result $false "$fs formatında /R yok. Hızlı moda geçiliyor."
        $modGirdi = '1'
    }

    $parametre = if ($modGirdi -eq '2') { '/R /X' } else { '/F /X' }

    if ($secilen.Sistem) {
        Write-Host ""
        Write-Host "  $secimAdi" -ForegroundColor $Tema.Vurgu
        Write-Host "  Bu bir SİSTEM sürücüsü. Şimdi taranamaz." -ForegroundColor Yellow
        Write-Host "  Yeniden başlatmada taranacak şekilde planlanabilir." -ForegroundColor $Tema.Metin
        Write-Host ""
        $ok = Read-Host "  Planlansın mı? (E/H)"
        if ($ok.ToUpper() -eq 'E') {
            cmd /c "echo Y| chkdsk $harf`: $parametre" | Out-Null
            Write-Result $true "$secimAdi → yeniden başlatmada taranacak."
        } else {
            Write-Result $false "İşlem iptal edildi."
        }
        Write-Host ""; Read-Host "  Devam etmek için Enter'a basın"; return
    }

    Write-Host ""
    Write-Host "  ► Taranacak: $secimAdi" -ForegroundColor $Tema.Baslik
    Write-Host "  ► Mod: $parametre" -ForegroundColor $Tema.Baslik
    Write-Host "  /X sürücü bağlantısını geçici keser." -ForegroundColor $Tema.Soluk
    Write-Host "  Açık dosyalar kapanacak. Devam edilsin mi?" -ForegroundColor $Tema.Metin
    Write-Host ""
    $ok = Read-Host "  Devam? (E/H)"
    if ($ok.ToUpper() -ne 'E') {
        Write-Result $false "İşlem iptal edildi."
        Write-Host ""; Read-Host "  Devam etmek için Enter'a basın"; return
    }

    Write-Host ""
    Write-Host "  chkdsk çalışıyor: $secimAdi" -ForegroundColor Cyan
    Write-Host "  Lütfen bekleyin..." -ForegroundColor $Tema.Soluk
    Write-Host ""

    $arguman = "$harf`: $parametre"         
    $sonuc = Start-Process -FilePath "chkdsk.exe" `
                           -ArgumentList $arguman `
                           -NoNewWindow -Wait -PassThru

    Write-Host ""
    if ($sonuc.ExitCode -eq 0) {
        Write-Result $true "$secimAdi → temiz, hata bulunamadı."
    } elseif ($sonuc.ExitCode -eq 1) {
        Write-Result $true "$secimAdi → hatalar bulundu ve düzeltildi."
    } else {
        Write-Result $false "$secimAdi → tarama bitti (Kod: $($sonuc.ExitCode))."
    }

    Write-Host ""
    Read-Host "  Devam etmek için Enter'a basın"
}
# ===================== SÜRÜCÜ VE UYGULAMA YÖNETİMİ =====================

function Backup-Drivers {
    Show-Header "SÜRÜCÜ YEDEKLE"
    $hedef = Select-Folder "Sürücülerin yedekleneceği klasörü seçin"
    if (-not $hedef) { Write-Result $false "İşlem iptal edildi."; Write-Host ""; Read-Host "  Devam etmek için Enter'a basın"; return }

    $klasor = Join-Path $hedef ("Surucu_Yedek_" + (Get-Date -Format "yyyyMMdd_HHmm"))
    Write-Host ""
    $onay = Read-Host "  Sürücüler '$klasor' klasörüne yedeklenecek. Onaylıyor musunuz? (E/H)"
    if ($onay -ne "E" -and $onay -ne "e") {
        Write-Result $false "İşlem iptal edildi."; Write-Host ""; Read-Host "  Devam etmek için Enter'a basın"; return
    }

    $eskiProgress = $ProgressPreference
    $ProgressPreference = 'SilentlyContinue'
    try {
        New-Item -Path $klasor -ItemType Directory -Force | Out-Null

        Write-Host "  Sürücüler yedekleniyor, lütfen bekleyin..." -ForegroundColor Yellow
        Write-Host "  (Her yedeklenen sürücü canlı listelenecek.)" -ForegroundColor DarkGray
        Write-Host ""

       $sayac = 0
       Export-WindowsDriver -Online -Destination $klasor -ErrorAction Stop | ForEach-Object {
            $sayac++
            $no = $sayac.ToString().PadLeft(3)
            $ad = if ($_.OriginalFileName) { Split-Path $_.OriginalFileName -Leaf } else { "(bilinmeyen sürücü)" }
            $sinif = if ($_.ClassName) { $_.ClassName } else { "Genel" }
            Write-Host ("  [" + $no + "] ") -ForegroundColor Cyan -NoNewline
            Write-Host $ad -ForegroundColor Gray -NoNewline
            Write-Host ("   (" + $sinif + ")") -ForegroundColor DarkGray

            Write-Progress -Activity "Sürücüler yedekleniyor" `
                           -Status "$sayac sürücü yedeklendi..." `
                           -CurrentOperation $ad
        }
        Write-Progress -Activity "Sürücüler yedekleniyor" -Completed

        Write-Host ""
        if ($sayac -gt 0) {
            Write-Result $true "$sayac sürücü yedeklendi: $klasor"
        } else {
            Write-Result $false "Yedeklenecek sürücü bulunamadı."
        }
    } catch {
        Write-Result $false "Sürücü yedeklenemedi: $($_.Exception.Message)"
    } finally {
        $ProgressPreference = $eskiProgress
    }
    Write-Host ""
    Read-Host "  Devam etmek için Enter'a basın"
}

function Restore-Drivers {
    Show-Header "SÜRÜCÜ GERİ YÜKLE"
    $kaynak = Select-Folder "Yedeklenmiş sürücü klasörünü seçin"
    if (-not $kaynak) { Write-Result $false "İşlem iptal edildi."; Write-Host ""; Read-Host "  Devam etmek için Enter'a basın"; return }

    Write-Host ""
    $onay = Read-Host "  Sürücüler '$kaynak' klasöründen geri yüklenecek. Emin misiniz? (E/H)"
    if ($onay -ne "E" -and $onay -ne "e") {
        Write-Result $false "İşlem iptal edildi."; Write-Host ""; Read-Host "  Devam etmek için Enter'a basın"; return
    }
    try {
        $infVar = Get-ChildItem -Path $kaynak -Filter *.inf -Recurse -ErrorAction SilentlyContinue
        if (-not $infVar) {
            Write-Result $false "Seçilen klasörde .inf sürücü dosyası bulunamadı."
            Write-Host ""
            Read-Host "  Devam etmek için Enter'a basın"
            return
        }

        Write-Host "  Sürücüler yükleniyor, lütfen bekleyin..." -ForegroundColor Yellow
        pnputil /add-driver "$kaynak\*.inf" /subdirs /install
        $kod = $LASTEXITCODE

        switch ($kod) {
            0 {
                Write-Result $true "Sürücüler geri yüklendi."
            }
            259 {
                Write-Result $true "Tüm sürücüler zaten güncel — yüklenecek yeni sürücü yoktu."
            }
            3010 {
                Write-Result $true "Sürücüler geri yüklendi. Değişikliklerin tamamlanması için yeniden başlatın."
            }
            default {
                Write-Result $false "Sürücü geri yükleme tamamlandı ancak bazı sürücüler yüklenemedi (Kod: $kod)."
            }
        }
    } catch {
        Write-Result $false "Sürücü geri yüklenemedi: $($_.Exception.Message)"
    }
    Write-Host ""
    Read-Host "  Devam etmek için Enter'a basın"
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
    Show-Header "UYGULAMA LİSTESİ DIŞA/İÇE AKTAR"
    Write-Host "  1) Yüklü uygulama listesini dışa aktar (JSON)" -ForegroundColor White
    Write-Host "  2) JSON dosyasından uygulamaları içe aktar (kur)" -ForegroundColor White
    Write-Host ""

    if (-not $WingetVar) {
        Write-Result $false "Winget bulunamadı, bu işlem yapılamıyor."
        Write-Host ""
        Read-Host "  Devam etmek için Enter'a basın"
        return
    }

    $sec = Read-Host "  Seçiminiz (1/2)"
    if ($sec -eq "1") {
        $hedef = Select-Folder "JSON'un kaydedileceği klasörü seçin"
        if ($hedef) {
            $dosya = Join-Path $hedef "uygulama_listesi.json"
            winget export -o "$dosya" --accept-source-agreements | Out-Null
            if (Test-Path $dosya) {
                $boyutKB = [math]::Round((Get-Item $dosya).Length / 1KB, 1)
                Write-Result $true "Liste dışa aktarıldı: $dosya ($boyutKB KB)"
            } else {
                Write-Result $false "Dışa aktarma başarısız: dosya oluşturulamadı."
            }
        } else {
            Write-Result $false "İşlem iptal edildi."
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
                Write-Result $false "Seçilen dosya geçerli bir JSON değil veya boş. İşlem durduruldu."
                Write-Host ""
                Read-Host "  Devam etmek için Enter'a basın"
                return
            }

            $onay = Read-Host "  '$dosya' içindeki uygulamalar kurulacak. Onaylıyor musunuz? (E/H)"
            if ($onay -eq "E" -or $onay -eq "e") {

                Write-Host ""
                Write-Host "  Lütfen bekleyin, uygulamalar kuruluyor (canlı akacak)..." -ForegroundColor DarkGray
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
                Show-Line "  İÇE AKTARMA ÖZETİ" $Tema.Vurgu
                Show-Divider
                Show-Line ("  Zaten kurulu      : " + $zatenKurulu + " uygulama") $Tema.Metin
                Show-Line ("  Yeni kurulan      : " + $yeniKurulan + " uygulama") $Tema.Basari
                Show-Divider
                Show-Line ("  İşlenen toplam    : " + $toplam + " uygulama") $Tema.Baslik
                Show-Bottom
                Write-Host ""

                if ($kod -eq 0) {
                    if ($yeniKurulan -gt 0) {
                        Write-Result $true "$yeniKurulan uygulama yeni kuruldu, $zatenKurulu uygulama zaten kuruluydu."
                    } else {
                        Write-Result $true "Tüm uygulamalar ($zatenKurulu) zaten kuruluydu — yeni kurulum gerekmedi."
                    }
                } else {
                    Write-Result $false "İçe aktarma tamamlandı ancak bazı uygulamalar kurulamadı (Kod: $kod)."
                }
            } else {
                Write-Result $false "İşlem iptal edildi."
            }
        } else {
            Write-Result $false "İşlem iptal edildi."
        }
    } else {
        Write-Result $false "Geçersiz seçim."
    }
    Write-Host ""
    Read-Host "  Devam etmek için Enter'a basın"
}
function App-Uninstall {
    Show-Header "UYGULAMA KALDIR"
    Write-Host "  Yüklü tüm uygulamalar listeleniyor..." -ForegroundColor Yellow
    Write-Host ""
    if (-not $WingetVar) {
        Write-Result $false "Winget bulunamadı."
        Write-Host ""
        Read-Host "  Devam etmek için Enter'a basın"
        return
    }
    winget list
    Write-Host ""
    Write-Host "  Yukarıdaki listeden kaldırmak istediğiniz uygulamanın" -ForegroundColor Cyan
    Write-Host "  ID veya Ad bilgisini girin (boş bırakıp Enter = iptal)." -ForegroundColor Cyan
    Write-Host ""
    $hedef = Read-Host "  Kaldırılacak uygulama (ID veya Ad)"
    if ([string]::IsNullOrWhiteSpace($hedef)) {
        Write-Result $false "İşlem iptal edildi."
        Write-Host ""; Read-Host "  Devam etmek için Enter'a basın"; return
    }

    $gercekAd = $hedef

    $onay = Read-Host "  '$hedef' kaldırılsın mı? (E/H)"
    if ($onay -ne "E" -and $onay -ne "e") {
        Write-Result $false "İşlem iptal edildi."
        Write-Host ""; Read-Host "  Devam etmek için Enter'a basın"; return
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
            Write-Host "  ID ile bulunamadı, Ad ile deneniyor..." -ForegroundColor DarkGray
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
            Write-Result $false "'$gercekAd' zaten yüklü değildi (kaldırılacak bir şey yok)."
        } elseif (-not $halaVar) {
            Write-Result $true "'$gercekAd' başarıyla kaldırıldı ve doğrulandı."
        } else {
            Write-Result $false "'$gercekAd' hâlâ yüklü görünüyor (Kod: $kod). Kaldırma tamamlanamadı."
        }
    } catch {
        Write-Result $false "Kaldırma başarısız: $($_.Exception.Message)"
    }
    Write-Host ""
    Read-Host "  Devam etmek için Enter'a basın"
}
function Show-Help {
    Show-Header "YARDIM / HAKKINDA"
    Write-Host "  Bilgisayar Aracı" -ForegroundColor $Tema.Vurgu
    Write-Host "  Hazırlayan : Mehmet IŞIK" -ForegroundColor $Tema.Metin
    Write-Host "  Güncelleme : 04.07.2026" -ForegroundColor $Tema.Metin
    Write-Host ""
    Write-Host "  Bu araç; uygulama kurulumu, sistem bilgisi," -ForegroundColor $Tema.Metin
    Write-Host "  bakım/temizlik ve sürücü yönetimi sağlar." -ForegroundColor $Tema.Metin
    Write-Host ""
    Write-Host "  • Numara yazıp Enter ile işlemi seçin." -ForegroundColor $Tema.Soluk
    Write-Host "  • 0 yazıp Enter ile programdan çıkın." -ForegroundColor $Tema.Soluk
    Write-Host ""
    if ($WingetVar) {
        Write-Host "  • Winget (paket yöneticisi): YÜKLÜ ✓" -ForegroundColor $Tema.Basari
    } else {
        Write-Host "  • Winget (paket yöneticisi): YÜKLÜ DEĞİL ✗" -ForegroundColor $Tema.Hata
        Write-Host "    Kurulum için aşağıdan 'E' seçebilirsiniz." -ForegroundColor $Tema.Soluk
    }
    Write-Host ""

    $wh = Read-Host "  Winget kurulum yardımını görüntülemek ister misiniz? (E/H)"
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
            Write-Host "║" -ForegroundColor $Tema.Cerceve -NoNewline
            Write-Host (" " + $numara) -ForegroundColor $Tema.Vurgu -NoNewline
            Write-Host ($satirAd + (" " * ($bosluk - 1))) -ForegroundColor $Tema.Baslik -NoNewline
            Write-Host "║" -ForegroundColor $Tema.Cerceve
        }
        Show-Divider
        Show-Line "  T) Seçili numaraları kur (örn: 1,3,5)" $Tema.Vurgu
        Show-Line "  H) Tümünü kur" $Tema.Vurgu
        Show-Line "  0) Ana menüye dön" $Tema.Soluk
        Show-Bottom
        Write-Host ""
        $sec = Read-Host "  Seçiminiz"

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
                Write-Result $false "Winget kurulu olmadığı için uygulama kurulumu yapılamıyor."
                Write-Host ""
                Write-Host "  Winget'i kurmak için ana menü > 27) Yardım bölümünü kullanın" -ForegroundColor Yellow
                Write-Host "  veya programı yeniden başlatın (açılışta otomatik kurulmayı dener)." -ForegroundColor Yellow
                Write-Host ""
                Read-Host "  Devam etmek için Enter'a basın"
                continue   
            }
        }

        if ($sec -eq "H" -or $sec -eq "h") {
            foreach ($u in $Uygulamalar) {
                Install-App $u.Ad $u.Id $u.Kaynak
            }
            Write-Host ""; Read-Host "  Devam etmek için Enter'a basın"
        }
        elseif ($sec -eq "T" -or $sec -eq "t" -or $sec -match "[0-9]") {
            $numaralar = $sec -split "[,\s]+" | Where-Object { $_ -match "^\d+$" }
            foreach ($n in $numaralar) {
                $secilen = $Uygulamalar | Where-Object { $_.No -eq [int]$n }
                if ($secilen) {
                    Install-App $secilen.Ad $secilen.Id $secilen.Kaynak
                }
            }
            Write-Host ""; Read-Host "  Devam etmek için Enter'a basın"
        }
    }
}
# ===================== TEK DÜZ MENÜ (FLAT) =====================
$Menu = @(
    # ===== SOL SÜTUN (1–14) =====
    @{ No = 1;  Grup = "UYGULAMA";  Ad = "Uygulama Kurulumu (liste)";          Eylem = { Invoke-AppMenu } }
    @{ No = 2;  Grup = "UYGULAMA";  Ad = "Tüm Uygulamaları Güncelle";          Eylem = { Update-AllApps } }
    @{ No = 3;  Grup = "UYGULAMA";  Ad = "Uygulama Ara ve Kur (winget)";       Eylem = { Search-App } }
    @{ No = 4;  Grup = "UYGULAMA";  Ad = "Uygulama Listesi Dışa/İçe Aktar";    Eylem = { App-ExportImport } }
    @{ No = 5;  Grup = "UYGULAMA";  Ad = "Uygulama Kaldır";                    Eylem = { App-Uninstall } }

    @{ No = 6;  Grup = "TEMİZLİK";  Ad = "Geçici Dosyaları Temizle";           Eylem = { Clean-Temp } }
    @{ No = 7;  Grup = "TEMİZLİK";  Ad = "Windows Loglarını Temizle";          Eylem = { Clean-Logs } }
    @{ No = 8;  Grup = "TEMİZLİK";  Ad = "Windows Update Önbelleği";           Eylem = { Clean-WinUpdate } }
    @{ No = 9;  Grup = "TEMİZLİK";  Ad = "Geri Dönüşüm Kutusunu Boşalt";       Eylem = { Clean-RecycleBin } }
    @{ No = 10; Grup = "TEMİZLİK";  Ad = "Disk Temizleme (cleanmgr)";          Eylem = { Clean-Disk } }
    @{ No = 11; Grup = "TEMİZLİK";  Ad = "Ekran Kartı Sürücü Artıkları";       Eylem = { Clean-GpuLeftovers } }
    @{ No = 12; Grup = "TEMİZLİK";  Ad = "Sistem Dosyalarını Onar";            Eylem = { Repair-SystemFiles } }

    @{ No = 13; Grup = "SÜRÜCÜ";    Ad = "Sürücü Yedekle";                     Eylem = { Backup-Drivers } }
    @{ No = 14; Grup = "SÜRÜCÜ";    Ad = "Sürücü Geri Yükle";                  Eylem = { Restore-Drivers } }

    # ===== SAĞ SÜTUN (15–27) =====
    @{ No = 15; Grup = "BAKIM";     Ad = "Disk Kontrol ve Onarım (chkdsk)";    Eylem = { Repair-Disk } }
    @{ No = 16; Grup = "BAKIM";     Ad = "Güvenli USB Oluştur (Korumalı)";     Eylem = { Protect-USB } }
    @{ No = 17; Grup = "BAKIM";     Ad = "Windows Güncellemelerini Tara";      Eylem = { Start-WindowsUpdate } }
    @{ No = 18; Grup = "BAKIM";     Ad = "Ağ Ayarlarını Sıfırla";              Eylem = { Reset-Network } }
    @{ No = 19; Grup = "BAKIM";     Ad = "Geri Yükleme Noktası Oluştur";       Eylem = { New-RestorePoint } }
    @{ No = 20; Grup = "BAKIM";     Ad = "Yazıcı Kuyruğunu Temizle";           Eylem = { Clear-PrintQueue } }

    @{ No = 21; Grup = "BİLGİ";     Ad = "Sistem Bilgileri";                   Eylem = { Show-SystemInfo } }
    @{ No = 22; Grup = "BİLGİ";     Ad = "Disk Özeti";                         Eylem = { Show-DiskSummary } }
    @{ No = 23; Grup = "BİLGİ";     Ad = "Disk Sağlığı (SMART)";               Eylem = { Show-DiskHealth } }
    @{ No = 24; Grup = "BİLGİ";     Ad = "Başlangıç Programları";              Eylem = { Show-Startup } }
    @{ No = 25; Grup = "BİLGİ";     Ad = "Sistem Sağlık Özeti";                Eylem = { Show-HealthSummary } }

    @{ No = 26; Grup = "DİĞER";     Ad = "Yönetim Klasörleri Oluştur";         Eylem = { New-AdminFolders } }
    @{ No = 27; Grup = "DİĞER";     Ad = "Yardım / Hakkında";                  Eylem = { Show-Help } }
)

# ===================== YARDIMCI: MENÜ KOLONU OLUŞTUR =====================
function Get-Kolon {
    param(
        [string[]]$Gruplar,
        [hashtable]$Ikon,
        [array]$MenuListesi
    )
    $satirlar = @()
    foreach ($g in $Gruplar) {
        $ik = if ($Ikon.ContainsKey($g)) { $Ikon[$g] } else { "•" }
        $satirlar += [pscustomobject]@{ Tip = "Baslik"; Metin = (" " + $ik + " " + $g) }
        foreach ($m in ($MenuListesi | Where-Object { $_.Grup -eq $g })) {
            $satirlar += [pscustomobject]@{ Tip = "Oge"; No = $m.No; Ad = $m.Ad }
        }
    }
    return ,$satirlar
}

# ===================== ANA MENÜ (TEK DÜZ / FLAT) =====================
function Show-MainMenu {
    Clear-Host

    # ===== ÜST BAŞLIK BANDI =====
    Write-Host ("╔" + ("═" * $BoxWidth) + "╗") -ForegroundColor $Tema.Cerceve

    # 1. Üst Boşluk (Nefes Payı)
    Write-Host "║" -ForegroundColor $Tema.Cerceve -NoNewline
    Write-Host (" " * $BoxWidth) -NoNewline
    Write-Host "║" -ForegroundColor $Tema.Cerceve

    # 2. Ana Başlık
    $baslik = "✦  B İ L G İ S A Y A R   A R A C I  ✦"
    $bPad = [math]::Max(1, [math]::Floor(($BoxWidth - $baslik.Length) / 2))
    Write-Host "║" -ForegroundColor $Tema.Cerceve -NoNewline
    Write-Host ((" " * $bPad) + $baslik + (" " * ($BoxWidth - $baslik.Length - $bPad))) -ForegroundColor $Tema.Vurgu -NoNewline
    Write-Host "║" -ForegroundColor $Tema.Cerceve

    # 3. İç Ayraç (Başlık ile Slogan arası ince çizgi)
    $ayracUzunluk = $BoxWidth - 6 
    $ayrac = "─" * $ayracUzunluk
    $aPad = [math]::Floor(($BoxWidth - $ayracUzunluk) / 2)
    Write-Host "║" -ForegroundColor $Tema.Cerceve -NoNewline
    Write-Host ((" " * $aPad) + $ayrac + (" " * ($BoxWidth - $ayracUzunluk - $aPad))) -ForegroundColor $Tema.Soluk -NoNewline
    Write-Host "║" -ForegroundColor $Tema.Cerceve

    # 4. Slogan
    $slogan = "Kur • Güncelle • Temizle • Yedekle • Onar"
    $sPad = [math]::Max(1, [math]::Floor(($BoxWidth - $slogan.Length) / 2))
    Write-Host "║" -ForegroundColor $Tema.Cerceve -NoNewline
    Write-Host ((" " * $sPad) + $slogan + (" " * ($BoxWidth - $slogan.Length - $sPad))) -ForegroundColor $Tema.Soluk -NoNewline
    Write-Host "║" -ForegroundColor $Tema.Cerceve

    # 5. Alt Boşluk (Nefes Payı)
    Write-Host "║" -ForegroundColor $Tema.Cerceve -NoNewline
    Write-Host (" " * $BoxWidth) -NoNewline
    Write-Host "║" -ForegroundColor $Tema.Cerceve

    # ===== CANLI MİNİ SİSTEM DURUMU =====
    $durum = " Sistem durumu okunuyor..."
    try {
        $os = Get-CimInstance Win32_OperatingSystem -ErrorAction SilentlyContinue
        $cDisk = Get-CimInstance Win32_LogicalDisk -Filter "DeviceID='C:'" -ErrorAction SilentlyContinue
        
# Disk Hesabı
        $cTop = [math]::Round($cDisk.Size / 1GB, 0)
        $cBos = [math]::Round($cDisk.FreeSpace / 1GB, 0)
        $cYuzde = if ($cTop -gt 0) { [math]::Round((($cTop - $cBos) / $cTop) * 100) } else { 0 }
        
        # RAM Hesabı (Hem fiziksel hem sanal makine uyumlu)
        $ramTop = [math]::Round($os.TotalVisibleMemorySize / 1024 / 1024)
        $ramBos = [math]::Round($os.FreePhysicalMemory / 1024 / 1024, 1)
        # Güncellenmiş Durum Çıktısı
        $durum = " 💽 C: %$cYuzde dolu ($cBos GB boş)   🧠 RAM: $ramBos GB boş / $ramTop GB"
    } catch {}

    Write-Host ("╟" + ("─" * $BoxWidth) + "╢") -ForegroundColor $Tema.Cerceve
    
    $dPad = [math]::Max(1, $BoxWidth - $durum.Length)
    Write-Host "║" -ForegroundColor $Tema.Cerceve -NoNewline
    Write-Host ($durum + (" " * $dPad)).Substring(0, $BoxWidth) -ForegroundColor $Tema.Basari -NoNewline
    Write-Host "║" -ForegroundColor $Tema.Cerceve
    Write-Host ("╟" + ("─" * $BoxWidth) + "╢") -ForegroundColor $Tema.Cerceve
    
    # ===== İKONLU GRUP DAĞILIMI =====
    $ikon = @{
        "UYGULAMA" = "📦"; "BİLGİ" = "ℹ️ "; "TEMİZLİK" = "🧹"
        "BAKIM"    = "🔧"; "SÜRÜCÜ" = "💾"; "DİĞER"    = "⚙️ "
    }
    $solGruplar = @("UYGULAMA", "TEMİZLİK", "SÜRÜCÜ")
    $sagGruplar = @("BAKIM", "BİLGİ", "DİĞER")

    $solKolon = Get-Kolon -Gruplar $solGruplar -Ikon $ikon -MenuListesi $Menu
    $sagKolon = Get-Kolon -Gruplar $sagGruplar -Ikon $ikon -MenuListesi $Menu

    $satirSayisi = [math]::Max($solKolon.Count, $sagKolon.Count)
    $kolGenislik = [math]::Floor(($BoxWidth - 1) / 2)
    $sagGen = $BoxWidth - $kolGenislik - 1

    for ($i = 0; $i -lt $satirSayisi; $i++) {
        $solSatir = if ($i -lt $solKolon.Count) { $solKolon[$i] } else { $null }
        $sagSatir = if ($i -lt $sagKolon.Count) { $sagKolon[$i] } else { $null }

        Write-Host "║" -ForegroundColor $Tema.Cerceve -NoNewline

        # --- SOL HÜCRE ---
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

        Write-Host "│" -ForegroundColor $Tema.Cerceve -NoNewline

        # --- SAĞ HÜCRE ---
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

        Write-Host "║" -ForegroundColor $Tema.Cerceve
    }

    # ===== ALT BANT =====
    Write-Host ("╟" + ("─" * $BoxWidth) + "╢") -ForegroundColor $Tema.Cerceve

    $wtKurulu = $null -ne (Get-Command wt.exe -ErrorAction SilentlyContinue)
    if (-not $wtKurulu) {
        $wtPath = "$env:LOCALAPPDATA\Microsoft\WindowsApps\wt.exe"
        if (Test-Path $wtPath) { $wtKurulu = $true }
    }
    if (-not $wtKurulu) {
        $ipucu = "  💡 Daha modern bir görünüm için Windows Terminal önerilir."
        $ipucu2 = "     Kurulum: Menü 1 (Uygulama Kurulumu) ▸ 15 numara."
        Show-Line $ipucu "Yellow"
        Show-Line $ipucu2 $Tema.Soluk
        Write-Host ("╟" + ("─" * $BoxWidth) + "╢") -ForegroundColor $Tema.Cerceve
    }

    Show-Line "  ➤ Numara yazıp Enter'a basın  •  0) Çıkış" $Tema.Vurgu
    Show-Line "  Mehmet IŞIK  •  Bilgisayar Aracı  •  v2026" $Tema.Soluk
    Write-Host ("╚" + ("═" * $BoxWidth) + "╝") -ForegroundColor $Tema.Cerceve
    Write-Host ""
}

# ===================== ANA DÖNGÜ (TEK MENÜ) =====================
$cikis = $false
do {
    try {
        Show-MainMenu
        $sec = Read-Host "  Seçiminiz"

        if ($sec -eq "0") {
            $cikis = $true
        }
        elseif ($sec -match "^\d+$") {
            $secilen = $Menu | Where-Object { $_.No -eq [int]$sec }
            if ($secilen) {
                & $secilen.Eylem
            } else {
                Write-Host ""
                Write-Host "  Geçersiz numara: $sec" -ForegroundColor Red
                Start-Sleep -Milliseconds 900
            }
        }
        else {
            Write-Host ""
            Write-Host "  Lütfen geçerli bir numara girin." -ForegroundColor Red
            Start-Sleep -Milliseconds 900
        }
    }
    catch {
        [Console]::CursorVisible = $true
        Write-Host ""
        Write-Host "  İŞLEM SIRASINDA HATA OLUŞTU:" -ForegroundColor Red
        Write-Host ("  " + $_.Exception.Message) -ForegroundColor Red
        Write-Host ""
        Read-Host "  Devam etmek için Enter'a basın"
    }
} while (-not $cikis)

Clear-Host
Write-Host "Program kapatıldı. İyi günler, Mehmet IŞIK!" -ForegroundColor Cyan

