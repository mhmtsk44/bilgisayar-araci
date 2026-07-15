<#
    Uygulama İndirme-Güncelleme-Sürücü Yedek Alma-Temizleme Aracı
    Hazırlayan: Mehmet IŞIK
    Güncelleme: 15.07.2026
    Kullanım: Sağ tık -> "PowerShell ile çalıştır" veya yönetici PowerShell'de:
              powershell -ExecutionPolicy RemoteSigned -File "Bilgisayar_Araci.ps1"
    NOT: Dosyayı "UTF-8 with BOM" olarak kaydedin (Türkçe + çerçeve karakterleri için).
#>

# ===================== MODERN TEMA / RENK PALETİ =====================
# NOT: Bu palet bilinçli olarak dosyanın en başına konuldu. Betiğin ilk
# satırlarında (yönetici izniyle yeniden başlatma bloğu gibi) fonksiyon
# dışı kod $Tema.Uyari / $Tema.Hata gibi anahtarları kullanıyor; $Tema
# daha aşağıda tanımlansaydı o kod çalıştığı anda $Tema henüz $null olur
# ve "ForegroundColor" parametresine null enum değeri bağlanamazdı.
$Tema = @{
    Cerceve    = "DarkCyan"
    Vurgu      = "Cyan"
    Metin      = "Gray"
    Baslik     = "White"
    Basari     = "Green"
    Hata       = "Red"
    Soluk      = "DarkGray"
    Uyari      = "Yellow"      # Aktif uyarılar / devam eden işlemler
    UyariSoluk = "DarkYellow"  # Daha hafif tonlu uyarılar (yeniden deneme, bilgi notu)
    Bilgi      = "Cyan"        # Bilgilendirme / durum mesajları
}

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

# Ağ bağlantısı sorunlarını önlemek için TLS'i zorla (Eski sistemler için kritik).
# Destekliyorsa TLS 1.3 + TLS 1.2 birlikte denenir; desteklemiyorsa (örn. Windows 10) sessizce TLS 1.2'ye düşer.
try {
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12 -bor [Net.SecurityProtocolType]::Tls13
} catch {
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
}

# ===================== LOGLAMA ALTYAPISI =====================
$script:LogDosyasi = Join-Path $env:TEMP "winget-kurulum.log"

function Yaz-Log {
    param(
        [string]$Mesaj,
        [ValidateSet('BILGI','UYARI','HATA')]
        [string]$Seviye = 'BILGI'
    )
    $satir = "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')  [$Seviye]  $Mesaj"
    try { $satir | Out-File -FilePath $script:LogDosyasi -Append -Encoding UTF8 } catch {}
}

Yaz-Log "==== Yeni kurulum oturumu baslatildi ===="

function Confirm-Islem {
    param([string]$Soru = "Bu işlemi yapmak istediğinize emin misiniz?")
    Write-Host ""
    $cevap = Read-Host "  $Soru (E/H)"
    return ($cevap -eq "E" -or $cevap -eq "e")
}

function Confirm-YoksaIptal {
    # Dosya genelinde ~8 yerde el ile tekrarlanan kalıbı sadeleştirir:
    #   $onay = Read-Host "... (E/H)"
    #   if ($onay -ne "E" -and $onay -ne "e") {
    #       Write-Result $false "İşlem iptal edildi."; Wait-User; return
    #   }
    # Kullanım: if (-not (Confirm-YoksaIptal "Soru metni")) { return }
    param([string]$Soru)
    if (-not (Confirm-Islem $Soru)) {
        Write-Result $false "İşlem iptal edildi."
        Wait-User
        return $false
    }
    return $true
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
                Write-Host "        [$deneme/$MaksimumDeneme] Ag dalgalanmasi: $Url ($SaniyeBekle sn sonra tekrar denenecek)" -ForegroundColor $Tema.UyariSoluk
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
    Write-Host "        LTSC otomatik güncelleme görevi ayarlanıyor..." -ForegroundColor $Tema.Soluk
    Yaz-Log "LTSC guncelleme gorevi olusturma baslatildi."

    try {
        Unregister-ScheduledTask -TaskName $GorevAdi -Confirm:$false -ErrorAction SilentlyContinue

        $tetikleyici = New-ScheduledTaskTrigger -Weekly -DaysOfWeek Friday -At 12:00pm
        $psKomut = "Install-PackageProvider -Name NuGet -Force -Scope CurrentUser -ErrorAction SilentlyContinue; Set-PSRepository -Name PSGallery -InstallationPolicy Trusted -ErrorAction SilentlyContinue; Install-Script -Name winget-install -Force -Scope CurrentUser -ErrorAction SilentlyContinue; `$p = (Get-InstalledScript winget-install).InstalledLocation; & (Join-Path `$p 'winget-install.ps1') -Force"
        
        $eylem = New-ScheduledTaskAction -Execute "powershell.exe" -Argument "-WindowStyle Hidden -NonInteractive -NoProfile -Command `"$psKomut`""

        Register-ScheduledTask -TaskName $GorevAdi -Trigger $tetikleyici -Action $eylem -Description "LTSC sistemlerde Winget'i guncel tutmak icin haftalik kontrol yapar." -ErrorAction Stop | Out-Null
        
        Yaz-Log "LTSC guncelleme gorevi basariyla kaydedildi."
    } catch {
        Write-Host "        Güncelleme görevi oluşturulamadı!" -ForegroundColor $Tema.Hata
        Yaz-Log "LTSC guncelleme gorevi olusturma HATASI: $($_.Exception.Message)" 'HATA'
    }
}

# ===================== MANUEL YOL 2 (VCLibs + UI.Xaml + App Installer) =====================
function Install-WingetManuel {
    Write-Host "  [Yedek Yol] Manuel bagimlilik kurulumu deneniyor..." -ForegroundColor $Tema.Soluk
    Yaz-Log "Manuel yedek yol basladi."
    
    $mimari = if ($env:PROCESSOR_ARCHITECTURE -eq "ARM64") { "arm64" } else { "x64" }
    $tmp = $env:TEMP

    # Sideload politikasını değiştirmeden önce mevcut durumu kaydet ki
    # işlem bitince (başarılı/başarısız fark etmeksizin) eski haline döndürebilelim.
    $sk = "HKLM:\SOFTWARE\Policies\Microsoft\Windows\Appx"
    $skZatenVardi = Test-Path $sk
    $eskiSideloadDeger = $null
    $eskiSideloadVardi = $false
    try {
        if ($skZatenVardi) {
            $mevcut = Get-ItemProperty -Path $sk -Name "AllowAllTrustedApps" -ErrorAction SilentlyContinue
            if ($null -ne $mevcut) {
                $eskiSideloadVardi = $true
                $eskiSideloadDeger = $mevcut.AllowAllTrustedApps
            }
        }
    } catch { }

    try {
        if (-not $skZatenVardi) { New-Item -Path $sk -Force | Out-Null }
        New-ItemProperty -Path $sk -Name "AllowAllTrustedApps" -PropertyType DWord -Value 1 -Force -ErrorAction Stop | Out-Null
        Yaz-Log "Sideload politikasi ayarlandi (gecici)."
    } catch { Yaz-Log "Sideload ayarlanamadi: $($_.Exception.Message)" 'UYARI' }

    try {
        Write-Host "        VCLibs ($mimari)..." -ForegroundColor $Tema.Soluk
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
            Write-Host "        UI.Xaml ($($xamlBilgi.NuGetSurum))..." -ForegroundColor $Tema.Soluk
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

        Write-Host "        App Installer kuruluyor..." -ForegroundColor $Tema.Soluk
        $lisansli = $false
        if ($appIndirildi -and (Test-Path $license)) {
            $ap = $appinst; $lp = $license
            $lisansli = Invoke-ZamanAsimli -Saniye 120 -Kod { Add-AppxProvisionedPackage -Online -PackagePath $using:ap -LicensePath $using:lp -ErrorAction Stop | Out-Null }
        }
        if (-not $lisansli -and $appIndirildi) {
            $ap2 = $appinst
            Invoke-ZamanAsimli -Saniye 120 -Kod { Add-AppxPackage -Path $using:ap2 -ErrorAction SilentlyContinue } | Out-Null
        }

    } finally {
        # ===== Sideload politikasını eski haline döndür (kalıcı ayar değişikliği bırakma) =====
        # NOT: Bu blok artık "finally" içinde. Yukarıdaki indirme/kurulum adımlarından
        # biri beklenmedik şekilde kesintiye uğrasa bile (örn. Ctrl+C) çalışır; böylece
        # sistem sonsuza dek "Tüm güvenilen uygulamalara izin ver" modunda kalmaz.
        try {
            if ($eskiSideloadVardi) {
                New-ItemProperty -Path $sk -Name "AllowAllTrustedApps" -PropertyType DWord -Value $eskiSideloadDeger -Force -ErrorAction Stop | Out-Null
                Yaz-Log "Sideload politikasi onceki degerine (${eskiSideloadDeger}) geri dondu."
            } else {
                Remove-ItemProperty -Path $sk -Name "AllowAllTrustedApps" -ErrorAction SilentlyContinue
                Yaz-Log "Sideload politikasi kaldirildi (script oncesinde tanimli degildi)."
            }
        } catch { Yaz-Log "Sideload politikasi geri alinamadi: $($_.Exception.Message)" 'UYARI' }
    }
}

# ===================== WINGET KURULUM ANA FONKSİYONU =====================
function Install-Winget {
    param([switch]$Sessiz)
    
    if (-not $Sessiz) { Write-Host "Winget durumu kontrol ediliyor..." -ForegroundColor $Tema.Bilgi }
    if (Get-Command winget -ErrorAction SilentlyContinue) {
        if (-not $Sessiz) { Write-Host "Winget bu sistemde zaten kurulu!" -ForegroundColor $Tema.Basari }
        Yaz-Log "Winget zaten kurulu."
        
        # Zaten kuruluysa LTSC ise yine de görev atayalım (önceden kurulmuş ama görev atılmamış olabilir)
        if (Test-LTSC) { Kur-WingetLTSCGuncellemeGorevi }
        return $true
    }
Write-Host ""
    Write-Host "  Sistemde Winget (Windows Paket Yöneticisi) bulunamadı." -ForegroundColor $Tema.Uyari
    Write-Host "  Uygulama indirme ve güncelleme menülerinin çalışması için gereklidir." -ForegroundColor $Tema.Soluk
    if (-not (Confirm-Islem "Winget şimdi kurulsun mu?")) {
        Write-Host "  Winget kurulumu atlandı. Winget gerektiren menüler çalışmayacaktır." -ForegroundColor $Tema.Hata
        Yaz-Log "Winget kurulumu kullanıcı tarafından iptal edildi." 'UYARI'
        Start-Sleep -Seconds 2
        return $false
    }
    Write-Host "Sistem mimarisi inceleniyor..." -ForegroundColor $Tema.Bilgi
    $ltsc = Test-LTSC

    if ($ltsc) {
        Write-Host "SİSTEM TESPİTİ: LTSC / LTSB Sürümü!" -ForegroundColor $Tema.Uyari
        Write-Host "Özel LTSC yöntemi (PSGallery) başlatılıyor..." -ForegroundColor $Tema.Soluk

        try {
            $basarili = Invoke-ZamanAsimli -Saniye 240 -Kod {
                Install-PackageProvider -Name NuGet -Force -Scope CurrentUser -ErrorAction SilentlyContinue | Out-Null
                Set-PSRepository -Name PSGallery -InstallationPolicy Trusted -ErrorAction SilentlyContinue
                Install-Script -Name winget-install -Force -Scope CurrentUser -ErrorAction Stop
                $p = (Get-InstalledScript winget-install -ErrorAction Stop).InstalledLocation
                & (Join-Path $p "winget-install.ps1") -Force
            }
            if (-not $basarili) {
                Write-Host "LTSC birincil yolu (PSGallery) tamamlanamadi." -ForegroundColor $Tema.Hata
                Yaz-Log "LTSC PSGallery yolu tamamlanamadi." 'HATA'
            } else {
                # --- GÜNCELLEME GÖREVİ BURADA ÇAĞRILIYOR ---
                Kur-WingetLTSCGuncellemeGorevi
            }
        } catch {
            Write-Host "LTSC kurulumu sirasinda hata." -ForegroundColor $Tema.Hata
            Yaz-Log "LTSC kurulum istisnasi: $($_.Exception.Message)" 'HATA'
        }

    } else {
        Write-Host "SİSTEM TESPİTİ: Standart Windows Sürümü." -ForegroundColor $Tema.Basari
        Write-Host "Normal kurulum (App Installer) başlatılıyor..." -ForegroundColor $Tema.Soluk
        
        # Indir-Dosya kullanılarak standart indirme daha güvenli hale getirildi
        $getwinget = Join-Path $env:TEMP "getwinget.msixbundle"
        if (Indir-Dosya "https://aka.ms/getwinget" $getwinget 120) {
            try { Add-AppxPackage -Path $getwinget -ErrorAction Stop; Yaz-Log "Standart paket kuruldu." }
            catch { Yaz-Log "Standart kurulum hatasi: $($_.Exception.Message)" 'HATA' }
        }
    }

    Start-Sleep -Seconds 3
    if (Get-Command winget -ErrorAction SilentlyContinue) {
        Write-Host "İşlem Tamamlandı: Winget başarıyla kuruldu (birincil yol)!" -ForegroundColor $Tema.Basari
        Temizle-GeciciDosyalar
        return $true
    }

    Write-Host "Birincil yol sonuc vermedi -> manuel yedek yola geciliyor..." -ForegroundColor $Tema.UyariSoluk
    Install-WingetManuel

    Start-Sleep -Seconds 3
    Temizle-GeciciDosyalar

    if (Get-Command winget -ErrorAction SilentlyContinue) {
        Write-Host "İşlem Tamamlandı: Winget başarıyla kuruldu (manuel yedek yol)!" -ForegroundColor $Tema.Basari
        if ($ltsc) { Kur-WingetLTSCGuncellemeGorevi } # Manuel yolla kurulduysa ve LTSC ise görev ata
        return $true
    } else {
        Write-Host "İşlem Başarısız: Winget kurulamadı. Log: $script:LogDosyasi" -ForegroundColor $Tema.Hata
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
    Write-Host "Yönetici izniyle yeniden başlatılıyor..." -ForegroundColor $Tema.Uyari
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
        Write-Host "HATA: Yönetici izni verilmedi veya yükseltme başarısız oldu." -ForegroundColor $Tema.Hata
        Write-Host "Ayrıntı: $($_.Exception.Message)" -ForegroundColor $Tema.UyariSoluk
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
# ===================== WINDOWS TERMINAL KONTROLÜ =====================
$script:WTKurulu = $null -ne (Get-Command wt.exe -ErrorAction SilentlyContinue)
if (-not $script:WTKurulu) {
    $wtPath = "$env:LOCALAPPDATA\Microsoft\WindowsApps\wt.exe"
    if (Test-Path $wtPath) { $script:WTKurulu = $true }
}
$ErrorActionPreference = "Continue"
$Host.UI.RawUI.WindowTitle = "Bilgisayar Aracı - Mehmet IŞIK"
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

# ===================== MODERN ÇERÇEVE =====================
# BoxWidth artık sabit 78 değil; konsol dar açıldıysa (ör. 80 sütunun altı)
# kutunun taşıp görüntüyü bozmaması için pencere genişliğine göre daralıyor.
# $genislik yukarıdaki pencere boyutlandırma bloğunda ayarlanmıştı; o blok
# çalışmadıysa (ör. ConsoleHost değilse) 78 varsayılanına düşüyoruz.
$BoxWidth = 78
if ($genislik -and $genislik -gt 0) {
    $BoxWidth = [math]::Max(60, [math]::Min(78, $genislik - 2))
}
function Show-Top    { Write-Host ("╔" + ("═" * $BoxWidth) + "╗") -ForegroundColor $Tema.Cerceve }
function Show-Bottom { Write-Host ("╚" + ("═" * $BoxWidth) + "╝") -ForegroundColor $Tema.Cerceve }
function Show-Divider{ Write-Host ("╟" + ("─" * $BoxWidth) + "╢") -ForegroundColor $Tema.Cerceve }
function Show-Line {
    param([string]$Metin, [string]$Renk = $Tema.Metin)

    # NOT: Basit .Length + Substring(0, N) yaklaşımı, çift-kod-birimli (surrogate pair)
    # emoji karakterlerini (ör. 💻) ortasından kesebiliyor ve bu da bozuk/eksik
    # karakterlere ya da ArgumentOutOfRangeException benzeri hatalara yol açabiliyordu.
    # Bunun yerine metni "text element" (grafem) bazında dolaşarak hem emojileri
    # bölmeden kesiyoruz hem de terminalde çift genişlik kaplayan karakterleri
    # doğru hesaba katıyoruz.
    $genisKarakterler = @('💻', '✨', '💡', '⚠️', '⚠', '✓', '✗', '🔧', '📀', '🖥️', '🗑️', '🖥')

    $elemanlar = @()
    $enumerator = [System.Globalization.StringInfo]::GetTextElementEnumerator($Metin)
    while ($enumerator.MoveNext()) { $elemanlar += [string]$enumerator.GetTextElement() }

    $sanalUzunluk = 0
    $temizParcalari = New-Object System.Collections.Generic.List[string]
    $tasti = $false

    foreach ($e in $elemanlar) {
        $genislik = if ($genisKarakterler -contains $e) { 2 } else { $e.Length }
        if (($sanalUzunluk + $genislik) -gt $BoxWidth) { $tasti = $true; break }
        $sanalUzunluk += $genislik
        $temizParcalari.Add($e)
    }

    $temiz = -join $temizParcalari
    if (-not $tasti) { $temiz = $Metin }  # Kesme gerekmediyse orijinal metni kullan (satır sonu boşluk vs. bozulmasın)

    $bosluk = [math]::Max(1, $BoxWidth - $sanalUzunluk)

    Write-Host "║" -ForegroundColor $Tema.Cerceve -NoNewline
    Write-Host (" " + $temiz + (" " * ($bosluk - 1))) -ForegroundColor $Renk -NoNewline
    Write-Host "║" -ForegroundColor $Tema.Cerceve
}

function Show-CenteredLine {
    # Show-Line'ın "sola yaslı + pad" mantığından farklı olarak metni ORTALAR.
    # Show-MainMenu içinde başlık / ayraç / slogan için 3 kez tekrarlanan
    # pad-hesaplama bloğunun yerini alır.
    param([string]$Metin, [string]$Renk = $Tema.Vurgu)
    $pad = [math]::Max(1, [math]::Floor(($BoxWidth - $Metin.Length) / 2))
    Write-Host "║" -ForegroundColor $Tema.Cerceve -NoNewline
    Write-Host ((" " * $pad) + $Metin + (" " * ($BoxWidth - $Metin.Length - $pad))) -ForegroundColor $Renk -NoNewline
    Write-Host "║" -ForegroundColor $Tema.Cerceve
}

function Write-MenuHucre {
    # Show-MainMenu'deki SOL/SAĞ hücre bloklarının ortak mantığı.
    # $Satir $null ise boş hücre basar; "Baslik" ise grup başlığı, aksi halde numaralı öğe basar.
    param($Satir, [int]$Genislik)

    if (-not $Satir) {
        Write-Host (" " * $Genislik) -NoNewline
        return
    }

    if ($Satir.Tip -eq "Baslik") {
        $m = $Satir.Metin
        if ($m.Length -gt $Genislik) { $m = $m.Substring(0, $Genislik) }
        Write-Host ($m + (" " * [math]::Max(0, $Genislik - $m.Length))) -ForegroundColor $Tema.Vurgu -NoNewline
    } else {
        $num = "  " + $Satir.No.ToString().PadLeft(2) + ") "
        $ad = $Satir.Ad
        if (($num + $ad).Length -gt $Genislik) { $ad = $ad.Substring(0, [math]::Max(0, $Genislik - $num.Length)) }
        $pad = [math]::Max(0, $Genislik - ($num.Length + $ad.Length))
        Write-Host $num -ForegroundColor $Tema.Vurgu -NoNewline
        Write-Host ($ad + (" " * $pad)) -ForegroundColor $Tema.Baslik -NoNewline
    }
}

function Show-Header {
    param([string]$Baslik)
    Clear-Host
    Show-Top
    Show-Line "  💻 BİLGİSAYAR ARACI" $Tema.Soluk
    Show-Line "  ────────────────────" $Tema.Soluk  # İnce ayraç metinle uyumlu kısaltıldı
    Show-Line "  ✨ $Baslik" $Tema.Vurgu
    Show-Bottom
    Write-Host ""
}

function Write-Result {
    param(
        [bool]$Basari,
        [string]$Mesaj = ""
    )
    if ($Basari) {
        Write-Host "  ✓  $Mesaj" -ForegroundColor $Tema.Basari
    } else {
        Write-Host "  ✗  $Mesaj" -ForegroundColor $Tema.Hata
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

    Wait-User
}

# ===================== WINGET KAYNAK GÜNCELLEME =====================
if ($WingetVar) {
    winget source update 2>$null | Out-Null
    if ($LASTEXITCODE -ne 0) {
        Write-Host "Uyari: winget kaynak guncellemesi tamamlanamadi." -ForegroundColor $Tema.UyariSoluk
    }
}

# ===================== YARDIMCI FONKSİYONLAR =====================

function Wait-User {
    Write-Host ""
    Read-Host "  Devam etmek için Enter'a basın"
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

    Write-Host "  $Ad kuruluyor..." -ForegroundColor $Tema.Uyari

    # Store uygulamaları için msstore kaynağı, diğerleri için varsayılan winget kaynağı
    if ($Kaynak -eq "msstore") {
        $argumanlar = "install --id $Id --source msstore --accept-package-agreements --accept-source-agreements"
    } else {
        $argumanlar = "install --id $Id --silent --accept-package-agreements --accept-source-agreements"
    }

    $sonuc = Start-Process winget -ArgumentList $argumanlar -Wait -PassThru -NoNewWindow
    switch ($sonuc.ExitCode) {
        0           {
            Write-Result $true "$Ad başarıyla kuruldu."
            if ($Id -eq "Microsoft.WindowsTerminal") { $script:WTKurulu = $true }
        }
        -1978335189 {
            Write-Result $true "$Ad zaten güncel / yüklü."
            if ($Id -eq "Microsoft.WindowsTerminal") { $script:WTKurulu = $true }
        }
        default     { Write-Result $false "$Ad kurulamadı (Kod: $($sonuc.ExitCode))." }
    }
}

# ===================== ALPEMIX ÖZEL İNDİRME (İMZA KONTROLLÜ) =====================
function Install-Alpemix {
    Write-Host "  Alpemix indiriliyor..." -ForegroundColor $Tema.Uyari
    try {
        $masaustu = [Environment]::GetFolderPath("Desktop")
        $hedef = Join-Path $masaustu "Alpemix.exe"
        $url = "https://www.alpemix.com/site/Alpemix.exe"

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
                Write-Host ("       İmzalayan: " + $imzaci) -ForegroundColor $Tema.Soluk
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
            Write-Host "  Bu dosyanın imzası doğrulanamadı. Yalnızca kaynağa" -ForegroundColor $Tema.Uyari
            Write-Host "  güveniyorsanız çalıştırın." -ForegroundColor $Tema.Uyari
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

# ===================== UYGULAMALARI GÜNCELLE (LİSTELE + SEÇMELİ/TÜMÜ) =====================
# NOT: Metin/tablo ayrıştırması YAPILMAZ. Resmi "Microsoft.WinGet.Client" PowerShell
# modülü kullanılır; bu modül uygulama bilgilerini hazır nesne (Id, Ad, Sürüm) olarak
# döndürür, bu yüzden dil/sürüm farklarına bağlı ayrıştırma hatası oluşamaz.
function Assert-WinGetModulu {
    if (Get-Module -ListAvailable -Name Microsoft.WinGet.Client) { return $true }

    Write-Host "  Gerekli PowerShell modülü (Microsoft.WinGet.Client) kuruluyor..." -ForegroundColor $Tema.Uyari
    Write-Host "  (Bu, yalnızca ilk kullanımda bir kez yapılır, lütfen bekleyin...)" -ForegroundColor $Tema.Soluk
    
    try {
        # 1. Arka plan gereksinimi olan NuGet'i sessizce kur
        Install-PackageProvider -Name NuGet -Force -Scope CurrentUser -ErrorAction SilentlyContinue | Out-Null
        
        # 2. Y/N onay sorusunda programın donmasını engellemek için depoyu güvenilir işaretle
        Set-PSRepository -Name "PSGallery" -InstallationPolicy Trusted -ErrorAction SilentlyContinue

        # 3. Modülü indir ve kur (-AllowClobber eklenerek olası çakışmalar ezilir)
        Install-Module -Name Microsoft.WinGet.Client -Force -AllowClobber -Scope CurrentUser -Repository PSGallery -ErrorAction Stop
        
        Yaz-Log "Microsoft.WinGet.Client modulu kuruldu."
        return $true
    } catch {
        Yaz-Log "Microsoft.WinGet.Client modulu kurulamadi: $($_.Exception.Message)" 'HATA'
        return $false
    }
}
function Update-AllApps {
    Show-Header "UYGULAMALARI GÜNCELLE"

    if (-not $WingetVar) {
        Show-WingetHelp
        return
    }

    if (-not (Assert-WinGetModulu)) {
        Write-Result $false "Gerekli PowerShell modülü kurulamadı, liste alınamıyor."
        Write-Host "  İnternet bağlantınızı kontrol edip tekrar deneyin." -ForegroundColor $Tema.Soluk
        Wait-User
        return
    }

    try {
        Import-Module Microsoft.WinGet.Client -ErrorAction Stop
    } catch {
        Write-Result $false "Modül yüklenemedi: $($_.Exception.Message)"
        Wait-User
        return
    }

    Write-Host "  Güncellenebilir uygulamalar aranıyor, lütfen bekleyin..." -ForegroundColor $Tema.Vurgu
    Write-Host ""

    try {
        # Get-WinGetPackage nesne döndürür; metin ayrıştırma YOK.
        $paketler = Get-WinGetPackage -ErrorAction Stop | Where-Object { $_.IsUpdateAvailable }
    } catch {
        Write-Result $false "Uygulama listesi alınamadı: $($_.Exception.Message)"
        Wait-User
        return
    }

    if (-not $paketler) {
        Write-Result $true "Güncellenecek uygulama bulunamadı — her şey güncel."
        Wait-User
        return
    }

    $uygulamaListesi = @()
    $sayac = 0
    foreach ($p in $paketler) {
        $sayac++
        $yeniSurum = if ($p.AvailableVersions -and $p.AvailableVersions.Count -gt 0) { $p.AvailableVersions[0] } else { "?" }
        $uygulamaListesi += [PSCustomObject]@{
            No     = $sayac
            Ad     = $p.Name
            Id     = $p.Id
            Mevcut = $p.InstalledVersion
            Yeni   = $yeniSurum
        }
    }

    Write-Host ""
    Show-Top
    Show-Line "  GÜNCELLENEBİLİR UYGULAMALAR" $Tema.Baslik
    Show-Divider
    foreach ($u in $uygulamaListesi) {
        $satirMetin = "  {0}) {1}  ({2} → {3})" -f $u.No.ToString().PadLeft(2), $u.Ad, $u.Mevcut, $u.Yeni
        Show-Line $satirMetin $Tema.Metin
    }
    Show-Bottom
    Write-Host ""

    Write-Host "  [Numara] Sadece seçilenleri güncelle (örn: 1,3,5)" -ForegroundColor $Tema.Vurgu
    Write-Host "  H) Hepsini güncelle" -ForegroundColor $Tema.Vurgu
    Write-Host "  0) İptal / Ana menüye dön" -ForegroundColor $Tema.Soluk
    Write-Host ""

    $sec = Read-Host "  Seçiminiz"

    if ($sec -eq "0" -or [string]::IsNullOrWhiteSpace($sec)) {
        Write-Result $false "İşlem iptal edildi."
        Wait-User
        return
    }

    if ($sec -eq "H" -or $sec -eq "h") {
        $secilenler = $uygulamaListesi
    } else {
        # Metinden sadece rakamları ayıkla
        $secilenNolar = $sec -split "[,\s]+" | Where-Object { $_ -match '^\d+$' } | ForEach-Object { [int]$_ }
        $secilenler = @($uygulamaListesi | Where-Object { $secilenNolar -contains $_.No })
        
        if (-not $secilenler) {
            Write-Result $false "Geçerli bir seçim yapılmadı."
            Wait-User
            return
        }
    }

    if (-not (Confirm-Islem "$($secilenler.Count) uygulama güncellensin mi?")) {
        Write-Result $false "İşlem iptal edildi."
        Wait-User
        return
    }

    Write-Host ""
    Write-Host "  Seçilen uygulamalar güncelleniyor, lütfen bekleyin..." -ForegroundColor $Tema.Vurgu
    Write-Host ""

    $basarili  = 0
    $basarisiz = 0
    $toplam    = $secilenler.Count
    $i         = 0

    foreach ($u in $secilenler) {
        $i++
        Write-Progress -Activity "Uygulamalar güncelleniyor" -Status "[$i/$toplam] $($u.Ad)" -PercentComplete (($i / $toplam) * 100)
        Write-Host ("  ▸ [$i/$toplam] " + $u.Ad + " güncelleniyor...") -ForegroundColor $Tema.Uyari
        try {
            $sonuc = Update-WinGetPackage -Id $u.Id -Mode Silent -ErrorAction Stop
            $kod = $sonuc.InstallerErrorCode
            if ($null -eq $kod -or $kod -eq 0) {
                Write-Result $true ($u.Ad + " güncellendi.")
                $basarili++
            } else {
                Write-Result $false ($u.Ad + " güncellenemedi (Kod: $kod).")
                $basarisiz++
            }
        } catch {
            Write-Result $false ($u.Ad + " güncellenemedi: " + $_.Exception.Message)
            $basarisiz++
        }
    }
    Write-Progress -Activity "Uygulamalar güncelleniyor" -Completed

    # ===== ÖZET KUTUSU =====
    Write-Host ""
    Show-Top
    Show-Line "  GÜNCELLEME ÖZETİ" $Tema.Baslik
    Show-Divider
    Show-Line ("  Başarılı   : " + $basarili) $Tema.Basari
    if ($basarisiz -gt 0) {
        Show-Line ("  Başarısız  : " + $basarisiz) $Tema.Hata
    }
    Show-Bottom

    Wait-User
}
# ===================== SİSTEM FONKSİYONLARI =====================

function New-AdminFolders {
    Show-Header "YÖNETİM KLASÖRLERİ OLUŞTUR"
    Write-Host ""
    if (-not (Confirm-YoksaIptal "Masaüstünde Admin ve GodMode klasörleri oluşturulsun mu?")) { return }
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
    Wait-User
}

# ===================== BİLGİ ALT MENÜSÜ =====================
function Invoke-BilgiMenusu {
    while ($true) {
        Clear-Host
        Show-Header "SİSTEM BİLGİLERİ"

        Write-Host "  Lütfen görüntülemek istediğiniz bilgiyi seçin:" -ForegroundColor $Tema.Metin
        Write-Host ""
        Write-Host "  [1] Sistem Bilgileri" -ForegroundColor $Tema.Vurgu
        Write-Host "  [2] Disk Özeti" -ForegroundColor $Tema.Vurgu
        Write-Host "  [3] Disk Sağlığı (SMART)" -ForegroundColor $Tema.Vurgu
        Write-Host "  [4] Başlangıç Programları" -ForegroundColor $Tema.Vurgu
        Write-Host "  [5] Sistem Sağlık Özeti" -ForegroundColor $Tema.Vurgu
        Write-Host "  [0] Ana Menüye Dön" -ForegroundColor $Tema.Soluk
        Write-Host ""

        $secim = Read-Host "  Seçiminiz"

        switch ($secim) {
            "1" { Show-SystemInfo }
            "2" { Show-DiskSummary }
            "3" { Show-DiskHealth }
            "4" { Show-Startup }
            "5" { Show-HealthSummary }
            "0" { return }
            default {
                Write-Host "  Geçersiz seçim. Lütfen tekrar deneyin." -ForegroundColor $Tema.Hata
                Start-Sleep -Seconds 2
            }
        }
    }
}
function Show-SystemInfo {
    Show-Header "SİSTEM BİLGİLERİ"
    try {
        $os  = Get-CimInstance Win32_OperatingSystem
        $cs  = Get-CimInstance Win32_ComputerSystem
        $cpu = Get-CimInstance Win32_Processor | Select-Object -First 1
        
        # YENİ: Doğrudan anakarttan fiziksel RAM modüllerinin toplamını okuma
        $fizikselRam = Get-CimInstance Win32_PhysicalMemory -ErrorAction SilentlyContinue | Measure-Object -Property Capacity -Sum
        
        # Eğer fiziksel RAM okunamazsa (sanal makine vs.), eski yönteme (OS) yedek olarak düş
        if ($fizikselRam.Sum -gt 0) {
            $ram = [math]::Round($fizikselRam.Sum / 1GB)
        } else {
            $ram = [math]::Round($os.TotalVisibleMemorySize / 1024 / 1024)
        }

        Write-Host ("  Bilgisayar : " + $cs.Name)          -ForegroundColor $Tema.Baslik
        Write-Host ("  İşletim S. : " + $os.Caption)       -ForegroundColor $Tema.Baslik
        Write-Host ("  Sürüm      : " + $os.Version)       -ForegroundColor $Tema.Metin
        Write-Host ("  İşlemci    : " + $cpu.Name.Trim())  -ForegroundColor $Tema.Metin
        Write-Host ("  RAM        : " + $ram + " GB")      -ForegroundColor $Tema.Metin
        Write-Host ("  Üretici    : " + $cs.Manufacturer)  -ForegroundColor $Tema.Metin
    } catch {
        Write-Host ("  Bilgi alınamadı: " + $_.Exception.Message) -ForegroundColor $Tema.Hata
    }
    Wait-User
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
    Wait-User
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
    Wait-User
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

    Wait-User
}

function Start-WindowsUpdate {
    Show-Header "WINDOWS GÜNCELLEMELERİ"
    Write-Host ""
    if (-not (Confirm-YoksaIptal "Windows güncellemeleri aranıp kurulsun mu?")) { return }
    try {
        if (-not (Get-Module -ListAvailable -Name PSWindowsUpdate)) {
            Write-Progress -Activity "Windows Update" -Status "PSWindowsUpdate modülü kuruluyor..." -PercentComplete 10
            Write-Host "  [1/3] PSWindowsUpdate modülü kuruluyor..." -ForegroundColor $Tema.Uyari
            Install-PackageProvider -Name NuGet -Force -ErrorAction SilentlyContinue | Out-Null
            Install-Module PSWindowsUpdate -Force -Scope CurrentUser -Confirm:$false -ErrorAction SilentlyContinue
        } else {
            Write-Host "  [1/3] PSWindowsUpdate modülü hazır." -ForegroundColor $Tema.Soluk
        }

        Write-Progress -Activity "Windows Update" -Status "Modül yükleniyor..." -PercentComplete 40
        Import-Module PSWindowsUpdate -ErrorAction SilentlyContinue

        Write-Progress -Activity "Windows Update" -Status "Güncellemeler aranıyor ve kuruluyor..." -PercentComplete 70
        Write-Host "  [2/3] Güncellemeler aranıyor..." -ForegroundColor $Tema.Uyari
        Write-Host "  [3/3] Bulunanlar kuruluyor (bu işlem uzun sürebilir)..." -ForegroundColor $Tema.Uyari
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
    Wait-User
}

function Reset-Network {
    Show-Header "AĞ SIFIRLAMA"
    Write-Host ""
if (-not (Confirm-Islem "Ağ ayarları sıfırlanacak (DNS, Winsock, IP). Emin misiniz?")) {
    Write-Result $false "İşlem iptal edildi."
    Wait-User; return
}

    try {
        ipconfig /flushdns | Out-Null
        netsh winsock reset | Out-Null
        netsh int ip reset | Out-Null
        Write-Result $true "Ağ ayarları sıfırlandı. Bilgisayarı yeniden başlatın."
    } catch {
        Write-Result $false "Ağ sıfırlanamadı: $($_.Exception.Message)"
    }
    Wait-User
}

function New-RestorePoint {
    Show-Header "SİSTEM GERİ YÜKLEME NOKTASI"
    Write-Host ""
    if (-not (Confirm-YoksaIptal "Sistem geri yükleme noktası oluşturulsun mu?")) { return }

try {
        Enable-ComputerRestore -Drive "C:\" -ErrorAction SilentlyContinue
        Checkpoint-Computer -Description "Bilgisayar Araci - $(Get-Date -Format 'yyyy-MM-dd HH:mm')" -RestorePointType "MODIFY_SETTINGS" -ErrorAction Stop
        Write-Result $true "Geri yükleme noktası oluşturuldu."
    } catch {
        Write-Result $false "Geri yükleme noktası oluşturulamadı: $($_.Exception.Message)"
    }

    Wait-User
}

function Clear-PrintQueue {
    Show-Header "YAZICI KUYRUĞUNU TEMİZLE"
    Write-Host ""
    if (-not (Confirm-YoksaIptal "Yazıcı kuyruğu temizlenecek. Onaylıyor musunuz?")) { return }
    try {
        Stop-Service -Name Spooler -Force -ErrorAction SilentlyContinue
        Remove-Item "$env:SystemRoot\System32\spool\PRINTERS\*" -Force -ErrorAction SilentlyContinue
        Start-Service -Name Spooler -ErrorAction SilentlyContinue
        Write-Result $true "Yazıcı kuyruğu temizlendi."
    } catch {
        Write-Result $false "Yazıcı kuyruğu temizlenemedi: $($_.Exception.Message)"
    }
    Wait-User
}

function Show-HealthSummary {
    Show-Header "SİSTEM SAĞLIK ÖZETİ"
    try {
        $os  = Get-CimInstance Win32_OperatingSystem
        
        # YENİ: Toplam RAM'i anakarttan (fiziksel), boş RAM'i ise işletim sisteminden (anlık) okuma
        $fizikselRam = Get-CimInstance Win32_PhysicalMemory -ErrorAction SilentlyContinue | Measure-Object -Property Capacity -Sum
        if ($fizikselRam.Sum -gt 0) {
            $ramTop = [math]::Round($fizikselRam.Sum / 1GB)
        } else {
            $ramTop = [math]::Round($os.TotalVisibleMemorySize / 1024 / 1024)
        }
        
        $bosRam = [math]::Round($os.FreePhysicalMemory / 1024 / 1024, 1)
        
        $cDisk = Get-CimInstance Win32_LogicalDisk -Filter "DeviceID='C:'"
        $cBos = [math]::Round($cDisk.FreeSpace / 1GB, 1)
        $cTop = [math]::Round($cDisk.Size / 1GB, 1)
        $uptime = (Get-Date) - $os.LastBootUpTime

        Write-Host ("  RAM        : " + $ramTop + " GB  (Boş: " + $bosRam + " GB)") -ForegroundColor $Tema.Baslik
        Write-Host ("  C: Disk    : " + $cTop + " GB  (Boş: " + $cBos + " GB)") -ForegroundColor $Tema.Baslik
        Write-Host ("  Çalışma S. : " + $uptime.Days + " gün " + $uptime.Hours + " saat") -ForegroundColor $Tema.Metin

        $cYuzde = if ($cTop -gt 0) { [math]::Round((($cTop - $cBos) / $cTop) * 100) } else { 0 }
        Write-Host ("  " + ("-" * 50)) -ForegroundColor $Tema.Cerceve
        if ($cYuzde -gt 90) { Write-Host "  ⚠ C: sürücüsü neredeyse dolu!" -ForegroundColor $Tema.Hata }
        elseif ($cYuzde -gt 75) { Write-Host "  ⚠ C: sürücüsünde yer azalıyor." -ForegroundColor $Tema.Uyari }
        else { Write-Host "  ✓ Disk durumu iyi." -ForegroundColor $Tema.Basari }

        if ($bosRam -lt 1.5) { Write-Host "  ⚠ Boş RAM düşük, sistem yavaşlayabilir!" -ForegroundColor $Tema.Hata }
        else { Write-Host "  ✓ RAM durumu iyi." -ForegroundColor $Tema.Basari }
    } catch {
        Write-Host ("  Sağlık özeti alınamadı: " + $_.Exception.Message) -ForegroundColor $Tema.Hata
    }
    Wait-User
}

# ===================== GÜVENLİK: TEHLİKELİ YOL KONTROLÜ (SON HAL v2) =====================

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
        '\\recent$',
        '\\softwaredistribution\\download$' 
    )
    
    foreach ($desen in $izinliDesenler) {
        if ($tam -imatch $desen) { return $true }
    }

    return $false
}
# ===================== TEMİZLİK FONKSİYONLARI =====================
function Remove-KlasorIcerigi {
    # Clean-Temp içinde Kategori 1, 3 ve 4'te BİREBİR tekrarlanan (~20 satır x 3) bloğu
    # ortaklaştırır: bir klasördeki dosyaları+alt klasörleri siler, boyutu hesaplar,
    # başarılıysa özet satırını yazdırır. Çağıran taraf dönen değerleri toplamlara ekler.
    param(
        [string]$Ad,
        [string]$Yol
    )
    $sonuc = @{ Silinen = 0; KazancMB = 0.0; Hata = 0 }

    $dosyalar = Get-ChildItem -Path $Yol -Recurse -Force -File -ErrorAction SilentlyContinue
    foreach ($d in $dosyalar) {
        try {
            $boyutMB = $d.Length / 1MB
            Remove-Item -LiteralPath $d.FullName -Force -ErrorAction Stop
            $sonuc.KazancMB += $boyutMB
            $sonuc.Silinen++
        } catch { $sonuc.Hata++ }
    }

    Get-ChildItem -Path $Yol -Recurse -Force -Directory -ErrorAction SilentlyContinue |
        Sort-Object FullName -Descending |
        ForEach-Object { try { Remove-Item -LiteralPath $_.FullName -Force -Recurse -ErrorAction Stop } catch {} }

    if ($sonuc.Silinen -gt 0) {
        $kazancYuvarli = [math]::Round($sonuc.KazancMB, 2)
        Write-Host ("  ✓ " + $Ad.PadRight(22) + " temizlendi — $($sonuc.Silinen) dosya, $kazancYuvarli MB") -ForegroundColor $Tema.Basari
    }
    return $sonuc
}

function Clean-Temp {
    Show-Header "DERİN SİSTEM TEMİZLİĞİ"

    Write-Host "  Bu işlem bilgisayarınızdaki gereksiz yükleri temizler." -ForegroundColor $Tema.Metin
    Write-Host "  Aşağıdan temizlemek istediğiniz kategori(leri) seçin:" -ForegroundColor $Tema.Metin
    Write-Host ""
    Write-Host "   1) Geçici Sistem ve Kullanıcı Dosyaları (Temp, Prefetch)" -ForegroundColor $Tema.Metin
    Write-Host "   2) Tarayıcı Önbellekleri (Chrome, Edge - Şifrelere dokunulmaz)" -ForegroundColor $Tema.Metin
    Write-Host "   3) Windows Update İndirme Önbelleği" -ForegroundColor $Tema.Metin
    Write-Host "   4) Ekran Kartı Kurulum Artıkları (AMD/NVIDIA/Intel)" -ForegroundColor $Tema.Metin
    Write-Host "   5) Geri Dönüşüm Kutusu" -ForegroundColor $Tema.Metin
    Write-Host "   6) Gereksiz Windows Olay Günlükleri (Loglar)" -ForegroundColor $Tema.Metin
    Write-Host ""
    Write-Host "  [Numara] Sadece seçilenleri temizle (örn: 1,3,5)" -ForegroundColor $Tema.Vurgu
    Write-Host "  H) Hepsini temizle" -ForegroundColor $Tema.Vurgu
    Write-Host "  9) Geri Dön" -ForegroundColor $Tema.Soluk
    Write-Host "  0) Ana menüye dön" -ForegroundColor $Tema.Soluk
    Write-Host ""

    $secim = Read-Host "  Seçiminiz"

    if ($secim -eq "9") {
        return
    }
    if ($secim -eq "0") {
        $script:AnaMenuyeDon = $true
        return
    }
    if ([string]::IsNullOrWhiteSpace($secim)) {
        Write-Result $false "Geçerli bir seçim yapılmadı."
        Wait-User
        return
    }

    if ($secim -eq "H" -or $secim -eq "h") {
        $secilenKategoriler = @(1, 2, 3, 4, 5, 6)
    } else {
        $secilenKategoriler = $secim -split "[,\s]+" |
            Where-Object { $_ -match '^\d+$' } |
            ForEach-Object { [int]$_ } |
            Where-Object { $_ -ge 1 -and $_ -le 6 } |
            Select-Object -Unique

        if (-not $secilenKategoriler) {
            Write-Result $false "Geçerli bir seçim yapılmadı."
            Wait-User
            return
        }
    }

    $kategoriAdlari = @{
        1 = "Geçici Sistem/Kullanıcı Dosyaları"
        2 = "Tarayıcı Önbellekleri"
        3 = "Windows Update Önbelleği"
        4 = "GPU Kurulum Artıkları"
        5 = "Geri Dönüşüm Kutusu"
        6 = "Olay Günlükleri"
    }
    $secilenAdlar = $secilenKategoriler | Sort-Object | ForEach-Object { $kategoriAdlari[$_] }

Write-Host ""
Write-Host "  Seçilen $($secilenKategoriler.Count) kategori temizlenecek:" -ForegroundColor $Tema.Metin

foreach ($ad in $secilenAdlar) {
    Write-Host "   • $ad" -ForegroundColor $Tema.Vurgu
}

if (-not (Confirm-Islem "Bu işlemi onaylıyor musunuz?")) {
    Write-Result $false "İşlem iptal edildi."
    Wait-User
    return
}

    Write-Host ""
    $toplamKazanc  = 0.0
    $toplamSilinen = 0
    $toplamHata    = 0

    # ===== KATEGORİ 1: GEÇİCİ SİSTEM VE KULLANICI DOSYALARI =====
    if ($secilenKategoriler -contains 1) {
        $hedeflerTemp = @(
            @{ Ad = "Kullanıcı TEMP";        Yol = $env:TEMP }
            @{ Ad = "Windows TEMP";          Yol = "$env:SystemRoot\Temp" }
            @{ Ad = "Yerel AppData TEMP";    Yol = "$env:LOCALAPPDATA\Temp" }
            @{ Ad = "Prefetch";              Yol = "$env:SystemRoot\Prefetch" }
            @{ Ad = "Thumbnail Önbellek";    Yol = "$env:LOCALAPPDATA\Microsoft\Windows\Explorer" }
            @{ Ad = "Son Kullanılanlar";     Yol = "$env:APPDATA\Microsoft\Windows\Recent" }
        )

        foreach ($k in $hedeflerTemp) {
            if ([string]::IsNullOrWhiteSpace($k.Yol) -or -not (Test-Path $k.Yol)) { continue }
            if (-not (Test-GuvenliYol $k.Yol)) { continue }

            $r = Remove-KlasorIcerigi -Ad $k.Ad -Yol $k.Yol
            if ($r.Silinen -gt 0) {
                $toplamKazanc  += $r.KazancMB
                $toplamSilinen += $r.Silinen
            }
            $toplamHata += $r.Hata
        }
    }

    # ===== KATEGORİ 2: TARAYICI ÖNBELLEKLERİ (CHROME & EDGE) =====
    if ($secilenKategoriler -contains 2) {
        $tarayicilar = @(
            @{ Ad = "Chrome"; Yol = Join-Path $env:LOCALAPPDATA "Google\Chrome\User Data"; Surec = "chrome" }
            @{ Ad = "Edge";   Yol = Join-Path $env:LOCALAPPDATA "Microsoft\Edge\User Data"; Surec = "msedge" }
        )
        $tarayiciGoreliYollar = @("History", "History-journal", "Cookies", "Cookies-journal", (Join-Path "Network" "Cookies"), (Join-Path "Network" "Cookies-journal"), "Local Storage", "Session Storage", "IndexedDB", "Service Worker", "databases", "shared_proto_db", "Cache", "Code Cache", "GPUCache", "Sessions")

        foreach ($tarayici in $tarayicilar) {
            if (Test-Path $tarayici.Yol) {
                $profiller = Get-ChildItem -Path $tarayici.Yol -Directory -ErrorAction SilentlyContinue | Where-Object { $_.Name -eq "Default" -or $_.Name -match '^Profile \d+$' }
                if ($profiller) {
                    $surecler = Get-Process -Name $tarayici.Surec -ErrorAction SilentlyContinue |
                                Where-Object { $_.MainWindowHandle -ne 0 }
                    $kapatildi = $true

                    if ($surecler) {
                        Write-Host ""
                        Write-Host ("  ⚠ $($tarayici.Ad) açık durumda.") -ForegroundColor $Tema.Uyari
                        $kapat = Read-Host "  Geçmiş ve önbellek temizliği için kapatılsın mı? (E/H)"
                        if ($kapat -match '^[EeYy]') {
			    try {
                                Get-Process -Name $tarayici.Surec -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction Stop
				Start-Sleep -Seconds 2
				}
                            catch { $kapatildi = $false; Write-Host ("  ⚠ $($tarayici.Ad) kapatılamadı, atlandı.") -ForegroundColor $Tema.Uyari }
                        } else { $kapatildi = $false }
                    }

                    if ($kapatildi) {
                        $silinen = 0; $kazancMB = 0.0
                        foreach ($profil in $profiller) {
                            # Crash Uyarısı Yaması
                            $prefYolu = Join-Path $profil.FullName "Preferences"
                            if (Test-Path $prefYolu) {
                                try {
                                    $prefIcerik = Get-Content -Path $prefYolu -Raw -ErrorAction SilentlyContinue
                                    if ($prefIcerik) {
                                        $prefIcerik = $prefIcerik -replace '"exit_type"\s*:\s*"Crashed"', '"exit_type":"Normal"'
                                        $prefIcerik = $prefIcerik -replace '"exited_cleanly"\s*:\s*false', '"exited_cleanly":true'
                                        $utf8NoBom = New-Object System.Text.UTF8Encoding $false
                                        [System.IO.File]::WriteAllText($prefYolu, $prefIcerik, $utf8NoBom)
                                    }
                                } catch { }
                            }

                            foreach ($goreliYol in $tarayiciGoreliYollar) {
                                $tamYol = Join-Path $profil.FullName $goreliYol
                                if (Test-Path $tamYol) {
                                    try {
                                        $boyutBytes = (Get-ChildItem -Path $tamYol -Recurse -Force -ErrorAction SilentlyContinue | Measure-Object -Property Length -Sum).Sum
                                        if ($null -ne $boyutBytes) { $kazancMB += ($boyutBytes / 1MB) }
                                        Remove-Item -Path $tamYol -Recurse -Force -ErrorAction Stop
                                        $silinen++
                                    } catch { $toplamHata++ }
                                }
                            }
                        }
                        if ($silinen -gt 0) {
                            $toplamKazanc += $kazancMB
                            $kazancYuvarli = [math]::Round($kazancMB, 2)
                            Write-Host ("  ✓ " + "$($tarayici.Ad) (Geçmiş)".PadRight(22) + " temizlendi — $silinen öğe, $kazancYuvarli MB") -ForegroundColor $Tema.Basari
                            $toplamSilinen += $silinen
                        }
                    }
                }
            }
        }
    }

    # ===== KATEGORİ 3: WINDOWS UPDATE İNDİRME ÖNBELLEĞİ =====
    if ($secilenKategoriler -contains 3) {
        # Önbelleği silebilmek için update servisini geçici olarak durdur
        Stop-Service -Name wuauserv -Force -ErrorAction SilentlyContinue

        $updateYolu = "$env:SystemRoot\SoftwareDistribution\Download"
        if ((Test-Path $updateYolu) -and (Test-GuvenliYol $updateYolu)) {
            $r = Remove-KlasorIcerigi -Ad "Windows Update" -Yol $updateYolu
            if ($r.Silinen -gt 0) {
                $toplamKazanc  += $r.KazancMB
                $toplamSilinen += $r.Silinen
            }
            $toplamHata += $r.Hata
        }

        # Update servisini geri başlat
        Start-Service -Name wuauserv -ErrorAction SilentlyContinue
    }

    # ===== KATEGORİ 4: EKRAN KARTI KURULUM ARTIKLARI (AMD/NVIDIA/INTEL) =====
    if ($secilenKategoriler -contains 4) {
        $hedeflerGPU = @(
            @{ Ad = "AMD Artıkları";         Yol = "$env:SystemDrive\AMD" }
            @{ Ad = "NVIDIA Artıkları";      Yol = "$env:SystemDrive\NVIDIA" }
            @{ Ad = "NVIDIA Temp 1";         Yol = "$env:WINDIR\Temp\NVIDIA Corporation" }
            @{ Ad = "NVIDIA Temp 2";         Yol = "$env:LOCALAPPDATA\Temp\NVIDIA Corporation" }
            @{ Ad = "Intel Artıkları";       Yol = "$env:SystemDrive\Intel" }
        )

        # GPU klasörleri yasaklı yollara takılmasın diye Test-GuvenliYol esnetildi
        # (Sistem sürücüsü C: olmayabilir, bu yüzden regex $env:SystemDrive'a göre kuruluyor)
        $gpuYolDeseni = '(?i)^' + [regex]::Escape($env:SystemDrive) + '\\(AMD|NVIDIA|Intel)(\\|$)'

        foreach ($k in $hedeflerGPU) {
            if ([string]::IsNullOrWhiteSpace($k.Yol) -or -not (Test-Path $k.Yol)) { continue }
            if (-not (Test-GuvenliYol $k.Yol) -and $k.Yol -notmatch $gpuYolDeseni) { continue }

            $r = Remove-KlasorIcerigi -Ad $k.Ad -Yol $k.Yol
            if ($r.Silinen -gt 0) {
                $toplamKazanc  += $r.KazancMB
                $toplamSilinen += $r.Silinen
            }
            $toplamHata += $r.Hata
        }
    }

    # ===== KATEGORİ 5: GERİ DÖNÜŞÜM KUTUSU =====
    if ($secilenKategoriler -contains 5) {
        try {
            $kutu = (New-Object -ComObject Shell.Application).NameSpace(10)
            $ogeSayisi = $kutu.Items().Count
            $ogeBoyutMB = 0.0

            if ($ogeSayisi -gt 0) {
                foreach ($oge in $kutu.Items()) {
                    try {
                        $byteBoyutu = $oge.ExtendedProperty("Size")
                        if ($null -ne $byteBoyutu) {
                            $ogeBoyutMB += ([double]$byteBoyutu / 1MB)
                        }
                    } catch {}
                }
            }

            if ($ogeSayisi -gt 0) {
                try {
                    Clear-RecycleBin -Force -ErrorAction Stop
                } catch {
                    # Clear-RecycleBin bazen işlem başarılı olsa bile COM uyarısı fırlatabilir.
                    # Gerçek durumu kutuyu tekrar kontrol ederek doğruluyoruz.
                }

                Start-Sleep -Milliseconds 500
                $kutuSonra = (New-Object -ComObject Shell.Application).NameSpace(10)
                $kalanSayisi = $kutuSonra.Items().Count

                if ($kalanSayisi -lt $ogeSayisi) {
                    $silinenSayisi = $ogeSayisi - $kalanSayisi
                    $kazancYuvarli = [math]::Round($ogeBoyutMB, 2)
                    Write-Host ("  ✓ " + "Çöp Kutusu".PadRight(22) + " temizlendi — $silinenSayisi öğe, ~$kazancYuvarli MB") -ForegroundColor $Tema.Basari
                    $toplamSilinen += $silinenSayisi
                    $toplamKazanc  += $ogeBoyutMB
                } else {
                    Write-Host ("  ⚠ Çöp Kutusu temizlenemedi.") -ForegroundColor $Tema.Hata
                    $toplamHata++
                }
            }

            # COM nesnelerini bellekten temizle
            [System.Runtime.Interopservices.Marshal]::ReleaseComObject($kutu) | Out-Null
            if ($null -ne $kutuSonra) {
                [System.Runtime.Interopservices.Marshal]::ReleaseComObject($kutuSonra) | Out-Null
            }
        } catch { $toplamHata++ }
    }
# ===== KATEGORİ 6: GEREKSİZ WINDOWS OLAY GÜNLÜKLERİ (LOGLAR) =====
    if ($secilenKategoriler -contains 6) {
        try {
            $loglar = @(wevtutil el 2>$null)
            if ($loglar.Count -gt 0) {
                Write-Host "  ▸ Loglar temizleniyor (bu işlem biraz sürebilir)..." -ForegroundColor $Tema.Soluk
                $logBasarili = 0
                $logBasarisiz = 0
                foreach ($log in $loglar) {
                    $psi = New-Object System.Diagnostics.ProcessStartInfo
                    $psi.FileName = "wevtutil.exe"; $psi.Arguments = "cl `"$log`""
                    $psi.UseShellExecute = $false; $psi.CreateNoWindow = $true
                    $proc = New-Object System.Diagnostics.Process; $proc.StartInfo = $psi
                    try {
                        $proc.Start() | Out-Null
                        # Zaman aşımı süresi büyük günlükler için 3 sn'den 30 sn'ye çıkarıldı.
                        $tamamlandi = $proc.WaitForExit(30000)
                        if ($tamamlandi -and $proc.ExitCode -eq 0) {
                            $logBasarili++
                        } else {
                            $logBasarisiz++
                        }
                    } catch { $logBasarisiz++ }
                }
                Write-Host ("  ✓ " + "Olay Günlükleri".PadRight(22) + " temizlendi — $logBasarili günlük.") -ForegroundColor $Tema.Basari
                if ($logBasarisiz -gt 0) {
                    Write-Host ("  ⚠ " + $logBasarisiz + " günlük temizlenemedi (kilitli/sistem günlüğü olabilir).") -ForegroundColor $Tema.Soluk
                }
                $toplamSilinen += $logBasarili
                $toplamHata    += $logBasarisiz
            }
        } catch { $toplamHata++ }
    }

    $kazancYuvarliToplam = [math]::Round($toplamKazanc, 2)

    # ===== ÖZET KUTUSU =====
    Write-Host ""
    Show-Top
    Show-Line "  DERİN TEMİZLİK ÖZETİ" $Tema.Baslik
    Show-Divider

    if ($secilenKategoriler.Count -eq 6) {
        Show-Line "  Temizlenen kategori : Tümü (6 Kategori)" $Tema.Metin
    } else {
        $kategoriMetni = $secilenAdlar -join ", "
        if ($kategoriMetni.Length -gt 52) {
            Show-Line ("  Temizlenen kategori : " + $secilenKategoriler.Count + " farklı kategori") $Tema.Metin
        } else {
            Show-Line ("  Temizlenen kategori : " + $kategoriMetni) $Tema.Metin
        }
    }
    Show-Line ("  Silinen dosya       : " + $toplamSilinen) $Tema.Metin
    Show-Line ("  Kazanılan alan      : " + $kazancYuvarliToplam + " MB (Tahmini alt sınır)") $Tema.Basari
    if ($toplamHata -gt 0) {
        Show-Line ("  Atlanan (kilitli)   : " + $toplamHata + " dosya (Normaldir)") $Tema.Soluk
    }
    Show-Bottom

    if ($secilenKategoriler -contains 1) {
        Write-Host ""
        Write-Host "  Not: Prefetch silindiği için ilk açılışlar biraz yavaş olabilir." -ForegroundColor $Tema.Soluk
        Write-Host "  Sistem kendini birkaç yeniden başlatmada optimize edecektir." -ForegroundColor $Tema.Soluk
    }

    Wait-User
}
function Clean-Disk {
    while ($true) {
        Clear-Host
        Show-Header "DİSK TEMİZLEME ARACI (cleanmgr)"
        
        Write-Host "  [1] Otomatik Temizlik (Arka planda güvenli dosyaları sessizce siler)" -ForegroundColor $Tema.Metin
        Write-Host "  [2] Gelişmiş Temizlik (Disk Temizleme arayüzünü açar)" -ForegroundColor $Tema.Metin
        Write-Host "  [9] Geri Dön" -ForegroundColor $Tema.Soluk
        Write-Host "  [0] Ana Menüye Dön" -ForegroundColor $Tema.Soluk
        Write-Host ""
        
        $sec = Read-Host "  Seçiminiz"

        # 9 ve 0 ana menüden çağrıldığı için ikisi de aynı yere (kök menüye) döndürür
        if ($sec -eq "9") {
            return
        }
        if ($sec -eq "0") {
            $script:AnaMenuyeDon = $true
            return
        }

        try {
            if ($sec -eq "1") {
                Write-Host ""
                Write-Host "  Otomatik temizlik yapılıyor, bu işlem diskinizin hızına göre sürebilir..." -ForegroundColor $Tema.Vurgu
                Start-Process cleanmgr -ArgumentList "/autoclean" -Wait
                Write-Result $true "Otomatik disk temizliği başarıyla tamamlandı."
            } elseif ($sec -eq "2") {
                Write-Host ""
                Write-Host "  Disk Temizleme arayüzü açılıyor..." -ForegroundColor $Tema.Vurgu
                Start-Process cleanmgr -ArgumentList "/d c:" -Wait
                Write-Result $true "Disk Temizleme aracı kapatıldı."
            } elseif ([string]::IsNullOrWhiteSpace($sec)) {
                Write-Result $false "İşlem iptal edildi."
                return
            } else {
                Write-Result $false "Geçersiz seçim, lütfen tekrar deneyin."
            }
        } catch {
            Write-Result $false "Disk Temizleme çalıştırılamadı: $($_.Exception.Message)"
        }
        
        Wait-User
    }
}
# ==================================================================================
#  HİBRİT PROTECT-USB  (v3.2)
# ==================================================================================
function Protect-USB {
    Show-Header "USB DİSK KORUMA / BİÇİMLENDİRME (HİBRİT v3.2)"

    $diskler = Get-Disk | Where-Object { $_.BusType -eq 'USB' }
    if (-not $diskler) {
        Write-Host "  Bağlı USB disk bulunamadı." -ForegroundColor $Tema.Hata
        Wait-User
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
        Wait-User
        return
    }

    $diskNo = 0
    if (-not [int]::TryParse($secim, [ref]$diskNo)) {
        Write-Result $false "Geçersiz disk numarası."
        Wait-User
        return
    }

    $hedefDisk = $diskler | Where-Object { $_.Number -eq $diskNo }
    if (-not $hedefDisk) {
        Write-Result $false "Belirtilen numarada USB disk bulunamadı."
        Wait-User
        return
    }

    if ($hedefDisk.BusType -ne 'USB') {
        Write-Host "  ⚠ UYARI: Bu disk USB değil! İşlem güvenlik nedeniyle durduruldu." -ForegroundColor $Tema.Hata
        Wait-User
        return
    }

    $diskBoyutGB = [math]::Round($hedefDisk.Size / 1GB, 1)
    if ($diskBoyutGB -gt 512) {
        Write-Host "  ⚠ UYARI: Disk çok büyük ($diskBoyutGB GB). Harici HDD olabilir." -ForegroundColor $Tema.Hata
        if (-not (Confirm-Islem "Yine de devam edilsin mi?")) {
            Write-Result $false "İşlem iptal edildi."
            Wait-User
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
                Wait-User
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
                    Wait-User
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

            Wait-User
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

            Wait-User
        }

        default {
            Write-Result $false "İşlem iptal edildi."
            Wait-User
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
    Write-Host "   [4] Tam Sistem Onarımı (DISM + SFC Birlikte)" -ForegroundColor $Tema.Vurgu
    Write-Host "   [0] Geri" -ForegroundColor $Tema.Soluk
    Write-Host ""

    $girdi = Read-Host "  Seçiminiz"

    [int]$anaSecim = 0
    if (-not [int]::TryParse($girdi, [ref]$anaSecim)) {
        Write-Result $false "Geçersiz giriş. Lütfen bir sayı girin."
        Wait-User
        return
    }

    switch ($anaSecim) {
        0 { return }

        1 {
            Write-Host ""
            Write-Host "  SFC taraması başlatılıyor..." -ForegroundColor $Tema.Metin
            sfc /scannow
            Wait-User
        }

        2 {
            Write-Host ""
            Write-Host "  DISM onarımı başlatılıyor..." -ForegroundColor $Tema.Metin
            DISM /Online /Cleanup-Image /RestoreHealth
            Wait-User
        }

        4 {
            Write-Host ""
            Write-Host "  SFC + DISM sırayla çalıştırılıyor..." -ForegroundColor $Tema.Metin
            sfc /scannow
            DISM /Online /Cleanup-Image /RestoreHealth
            Wait-User
        }

        3 {
            Invoke-ChkdskSecmeli
        }

        default {
            Write-Result $false "Geçersiz seçim: $anaSecim"
            Wait-User
        }
    }
}
function Invoke-ChkdskSecmeli {
    Show-Header "DİSK KONTROLÜ (CHKDSK)"

    try {
        $diskler = Get-Disk | Sort-Object Number -ErrorAction Stop
    } catch {
        Write-Result $false "Disk bilgisi alınamadı: $($_.Exception.Message)"
        Wait-User; return
    }

    if (-not $diskler) {
        Write-Result $false "Hiç disk bulunamadı."
        Wait-User; return
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
            Wait-User; return
        }

        $girdiSecim = Read-Host "  Taramak istediğin bölüm numarası (İptal için 0)"

        [int]$secim = 0
        if (-not [int]::TryParse($girdiSecim, [ref]$secim)) {
            Write-Result $false "Geçersiz giriş. Sayı girmelisiniz. Tekrar deneyin."
            continue   
        }
        if ($secim -eq 0) {
            Write-Result $false "İşlem iptal edildi."
            Wait-User; return
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
        Write-Host "  UYARI: $secimAdi" -ForegroundColor $Tema.Uyari
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
        Write-Host "  Bu bir SİSTEM sürücüsü. Şimdi taranamaz." -ForegroundColor $Tema.Uyari
        Write-Host "  Yeniden başlatmada taranacak şekilde planlanabilir." -ForegroundColor $Tema.Metin
        Write-Host ""
        $ok = Read-Host "  Planlansın mı? (E/H)"
        if ($ok.ToUpper() -eq 'E') {
            cmd /c "echo Y| chkdsk $harf`: $parametre" | Out-Null
            Write-Result $true "$secimAdi → yeniden başlatmada taranacak."
        } else {
            Write-Result $false "İşlem iptal edildi."
        }
        Wait-User; return
    }

    Write-Host ""
    Write-Host "  ► Taranacak: $secimAdi" -ForegroundColor $Tema.Baslik
    Write-Host "  ► Mod: $parametre" -ForegroundColor $Tema.Baslik
    Write-Host "  /X sürücü bağlantısını geçici keser." -ForegroundColor $Tema.Soluk
    Write-Host "  Açık dosyalar kapanacak. Devam edilsin mi?" -ForegroundColor $Tema.Metin
    Write-Host ""
    if (-not (Confirm-YoksaIptal "Devam?")) { return }

    Write-Host ""
    Write-Host "  chkdsk çalışıyor: $secimAdi" -ForegroundColor $Tema.Bilgi
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

    Wait-User
}

function Reset-DiskTablosu {
    Show-Header "DİSK TEMİZLE VE DÖNÜŞTÜR (GPT/MBR)"

    Write-Host "  Bu işlem, diskpart'taki 'clean' + 'convert gpt/mbr' komutlarının" -ForegroundColor $Tema.Metin
    Write-Host "  PowerShell karşılığıdır." -ForegroundColor $Tema.Metin
    Write-Host "  ⚠ Seçilen diskteki TÜM bölümler ve veriler kalıcı olarak silinir!" -ForegroundColor $Tema.Hata
    Write-Host ""

    try {
        $diskler = Get-Disk | Sort-Object Number -ErrorAction Stop
    } catch {
        Write-Result $false "Disk bilgisi alınamadı: $($_.Exception.Message)"
        Wait-User; return
    }

    if (-not $diskler) {
        Write-Result $false "Hiç disk bulunamadı."
        Wait-User; return
    }

    Write-Host "  Sistemdeki diskler:" -ForegroundColor $Tema.Vurgu
    Write-Host ""
    foreach ($d in $diskler) {
        $boyutGB  = [math]::Round($d.Size / 1GB, 1)
        $sistemMi = if ($d.IsBoot -or $d.IsSystem) { "  [SİSTEM DİSKİ]" } else { "" }
        $seri     = if ($d.SerialNumber) { $d.SerialNumber.Trim() } else { "bilinmiyor" }
        Write-Host ("   Disk {0}  |  {1}  |  {2} GB  |  {3}{4}" -f $d.Number, $d.FriendlyName, $boyutGB, $d.PartitionStyle, $sistemMi) -ForegroundColor $Tema.Metin
        Write-Host ("            Seri No: {0}" -f $seri) -ForegroundColor $Tema.Soluk
    }
    Write-Host ""

    $secim = Read-Host "  İşlem yapılacak disk numarasını girin (iptal için q)"
    if ($secim -eq 'q' -or [string]::IsNullOrWhiteSpace($secim)) {
        Write-Result $false "İşlem iptal edildi."
        Wait-User
        return
    }

    $diskNo = 0
    if (-not [int]::TryParse($secim, [ref]$diskNo)) {
        Write-Result $false "Geçersiz disk numarası."
        Wait-User
        return
    }

    $hedefDisk = $diskler | Where-Object { $_.Number -eq $diskNo }
    if (-not $hedefDisk) {
        Write-Result $false "Belirtilen numarada disk bulunamadı."
        Wait-User
        return
    }

    if ($hedefDisk.IsBoot -or $hedefDisk.IsSystem) {
        Write-Host "  ⚠ UYARI: Bu, Windows'un ÇALIŞTIĞI sistem diski!" -ForegroundColor $Tema.Hata
        Write-Host "  Güvenlik nedeniyle bu disk üzerinde işlem yapılamaz." -ForegroundColor $Tema.Hata
        Wait-User
        return
    }

    try {
        $sistemHarfi = $env:SystemDrive.TrimEnd(':')
        $hedefBolumler = Get-Partition -DiskNumber $diskNo -ErrorAction SilentlyContinue
        $sistemBolumVar = $hedefBolumler | Where-Object { $_.DriveLetter -eq $sistemHarfi }
        if ($sistemBolumVar) {
            Write-Host "  ⚠ UYARI: Bu diskte sistem sürücüsü ($sistemHarfi`:) bulundu!" -ForegroundColor $Tema.Hata
            Write-Host "  Güvenlik nedeniyle bu disk üzerinde işlem yapılamaz." -ForegroundColor $Tema.Hata
            Wait-User
            return
        }
    } catch { }

    $diskBoyutGB = [math]::Round($hedefDisk.Size / 1GB, 1)
    $hedefSeri   = if ($hedefDisk.SerialNumber) { $hedefDisk.SerialNumber.Trim() } else { "bilinmiyor" }

    Write-Host ""
    Write-Host ("  " + ("═" * 60)) -ForegroundColor $Tema.Hata
    Write-Host "  ⚠ KALICI VERİ SİLME İŞLEMİ" -ForegroundColor $Tema.Hata
    Write-Host ("   Disk Numarası : {0}" -f $hedefDisk.Number) -ForegroundColor $Tema.Metin
    Write-Host ("   Model         : {0}" -f $hedefDisk.FriendlyName) -ForegroundColor $Tema.Metin
    Write-Host ("   Seri No       : {0}" -f $hedefSeri) -ForegroundColor $Tema.Metin
    Write-Host ("   Boyut         : {0} GB" -f $diskBoyutGB) -ForegroundColor $Tema.Metin
    Write-Host ("   Mevcut Yapı   : {0}" -f $hedefDisk.PartitionStyle) -ForegroundColor $Tema.Metin
    Write-Host "   Silinecek     : Diskteki TÜM bölümler ve veriler" -ForegroundColor $Tema.Metin
    Write-Host ("  " + ("═" * 60)) -ForegroundColor $Tema.Hata
    Write-Host ""
    Write-Host "  Aynı modelde birden fazla diskiniz varsa, yukarıdaki Seri No'yu" -ForegroundColor $Tema.Soluk
    Write-Host "  kontrol ederek doğru diski seçtiğinizden emin olun." -ForegroundColor $Tema.Soluk
    Write-Host ""

    $onayMetni = "SIL $diskNo"
    $onay = Read-Host "  Onaylamak için şunu yazın: '$onayMetni'"
    if ($onay -ne $onayMetni) {
        Write-Result $false "Onay metni eşleşmedi. İşlem güvenlik nedeniyle iptal edildi."
        Wait-User
        return
    }

    Write-Host ""
    Write-Host "  Dönüştürülecek bölüm tablosu türünü seçin:" -ForegroundColor $Tema.Baslik
    Write-Host "   1) GPT (yeni sistemler, UEFI için)" -ForegroundColor $Tema.Metin
    Write-Host "   2) MBR (eski sistemler, BIOS/Legacy için)" -ForegroundColor $Tema.Metin
    Write-Host "   q) İptal" -ForegroundColor $Tema.Soluk
    Write-Host ""
    $stilSecim = Read-Host "  Seçiminiz"

    $partitionStyle = switch ($stilSecim) {
        "1" { "GPT" }
        "2" { "MBR" }
        default { $null }
    }

    if (-not $partitionStyle) {
        Write-Result $false "İşlem iptal edildi."
        Wait-User
        return
    }

    try {
        Write-Host ""
        Write-Host "  [1/2] Disk temizleniyor (clean)..." -ForegroundColor $Tema.Vurgu
        Clear-Disk -Number $diskNo -RemoveData -RemoveOEM -Confirm:$false -ErrorAction Stop
        
        Start-Sleep -Seconds 2 
        Write-Result $true "Disk temizlendi (tüm bölümler ve veriler silindi)."

        Write-Host ""
        Write-Host "  [2/2] Disk $partitionStyle olarak dönüştürülüyor (convert)..." -ForegroundColor $Tema.Vurgu
        
        try {
            Initialize-Disk -Number $diskNo -PartitionStyle $partitionStyle -ErrorAction Stop
        } catch {
            Set-Disk -Number $diskNo -PartitionStyle $partitionStyle -ErrorAction Stop
        }
        
        Write-Result $true "Disk başarıyla $partitionStyle olarak dönüştürüldü."
        
        Start-Sleep -Seconds 2 

        Write-Host ""
        Write-Host "  Not: Disk şu an bölümlendirilmemiş (RAW) durumda." -ForegroundColor $Tema.Soluk

        $bolumOlustur = Read-Host "  Diski hemen kullanılabilir hale getirmek için tam boyutlu bir bölüm oluşturulsun mu? (E/H)"
        if ($bolumOlustur -match "^[Ee]$") {
            try {
                if ($partitionStyle -eq "MBR") {
                    New-Partition -DiskNumber $diskNo -UseMaximumSize -IsActive -AssignDriveLetter -ErrorAction Stop | Out-Null
                } else {
                    New-Partition -DiskNumber $diskNo -UseMaximumSize -AssignDriveLetter -ErrorAction Stop | Out-Null
                }

                Start-Sleep -Seconds 2
                
                $yeniBolum = Get-Partition -DiskNumber $diskNo -ErrorAction SilentlyContinue | Where-Object DriveLetter | Select-Object -First 1
                             
                if ($yeniBolum -and $yeniBolum.DriveLetter) {
                    Format-Volume -Partition $yeniBolum -FileSystem NTFS -Confirm:$false -ErrorAction Stop | Out-Null
                    Write-Result $true ("Bölüm oluşturuldu ve NTFS ile biçimlendirildi: " + $yeniBolum.DriveLetter + ":")
                } else {
                    Write-Result $false "Bölüm oluşturuldu ama sürücü harfi atanamadı. Disk Yönetimi'nden manuel atayabilirsiniz."
                }
            } catch {
                Write-Result $false ("Bölüm oluşturulamadı: " + $_.Exception.Message)
            }
        } else {
            Write-Host "  Kullanılabilir hale getirmek için Disk Yönetimi'nden yeni bölüm oluşturun." -ForegroundColor $Tema.Soluk
        }
    } catch {
        Write-Result $false ("İşlem başarısız: " + $_.Exception.Message)
    }

    Wait-User
}
# ===================== SÜRÜCÜ VE UYGULAMA YÖNETİMİ =====================
function Invoke-SurucuMenusu {
    while ($true) {
        Clear-Host
        Show-Header "SÜRÜCÜ YÖNETİMİ"

        Write-Host "  Lütfen yapmak istediğiniz işlemi seçin:" -ForegroundColor $Tema.Metin
        Write-Host ""
        Write-Host "  [1] Sürücü Yedekle" -ForegroundColor $Tema.Vurgu
        Write-Host "  [2] Sürücü Geri Yükle" -ForegroundColor $Tema.Vurgu
        Write-Host "  [0] Ana Menüye Dön" -ForegroundColor $Tema.Soluk
        Write-Host ""

        $secim = Read-Host "  Seçiminiz"

        switch ($secim) {
            "1" { Backup-Drivers }
            "2" { Restore-Drivers }
            "0" { return }
            default {
                Write-Host "  Geçersiz seçim. Lütfen tekrar deneyin." -ForegroundColor $Tema.Hata
                Start-Sleep -Seconds 2
            }
        }
    }
}

function Backup-Drivers {
    Show-Header "SÜRÜCÜ YEDEKLE"
    $hedef = Select-Folder "Sürücülerin yedekleneceği klasörü seçin"
    if (-not $hedef) { Write-Result $false "İşlem iptal edildi."; Wait-User; return }

    $klasor = Join-Path $hedef ("Surucu_Yedek_" + (Get-Date -Format "yyyyMMdd_HHmm"))
    if (-not (Confirm-YoksaIptal "Sürücüler '$klasor' klasörüne yedeklenecek. Onaylıyor musunuz?")) { return }

    $eskiProgress = $ProgressPreference
    $ProgressPreference = 'SilentlyContinue'
    try {
        New-Item -Path $klasor -ItemType Directory -Force | Out-Null

        Write-Host "  Sürücüler yedekleniyor, lütfen bekleyin..." -ForegroundColor $Tema.Uyari
        Write-Host "  (Her yedeklenen sürücü canlı listelenecek.)" -ForegroundColor $Tema.Soluk
        Write-Host ""

       $sayac = 0
       Export-WindowsDriver -Online -Destination $klasor -ErrorAction Stop | ForEach-Object {
            $sayac++
            $no = $sayac.ToString().PadLeft(3)
            $ad = if ($_.OriginalFileName) { Split-Path $_.OriginalFileName -Leaf } else { "(bilinmeyen sürücü)" }
            $sinif = if ($_.ClassName) { $_.ClassName } else { "Genel" }
            Write-Host ("  [" + $no + "] ") -ForegroundColor $Tema.Bilgi -NoNewline
            Write-Host $ad -ForegroundColor Gray -NoNewline
            Write-Host ("   (" + $sinif + ")") -ForegroundColor $Tema.Soluk

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
    Wait-User
}

function Restore-Drivers {
    Show-Header "SÜRÜCÜ GERİ YÜKLE"
    $kaynak = Select-Folder "Yedeklenmiş sürücü klasörünü seçin"
    if (-not $kaynak) { Write-Result $false "İşlem iptal edildi."; Wait-User; return }

    if (-not (Confirm-YoksaIptal "Sürücüler '$kaynak' klasöründen geri yüklenecek. Emin misiniz?")) { return }
    try {
        $infVar = Get-ChildItem -Path $kaynak -Filter *.inf -Recurse -ErrorAction SilentlyContinue
        if (-not $infVar) {
            Write-Result $false "Seçilen klasörde .inf sürücü dosyası bulunamadı."
            Wait-User
            return
        }

        Write-Host "  Sürücüler yükleniyor, lütfen bekleyin..." -ForegroundColor $Tema.Uyari
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
    Wait-User
}

# ===================== UYGULAMA ARA VE KUR (winget search) =====================
function Test-GenisKarakter {
    param([Parameter(Mandatory)][char]$Karakter)
    $cp = [int]$Karakter
    # CJK Birleşik İdeogramlar, Hiragana/Katakana, Hangul, Fullwidth formlar vb.
    # Bu karakterler terminalde 1 değil 2 sütun genişliğinde görünür.
    return (
        ($cp -ge 0x1100  -and $cp -le 0x115F) -or
        ($cp -ge 0x2E80  -and $cp -le 0xA4CF) -or
        ($cp -ge 0xAC00  -and $cp -le 0xD7A3) -or
        ($cp -ge 0xF900  -and $cp -le 0xFAFF) -or
        ($cp -ge 0xFF00  -and $cp -le 0xFF60) -or
        ($cp -ge 0xFFE0  -and $cp -le 0xFFE6)
    )
}

function Convert-GorselKolonaKarakterIndeksi {
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Satir, [Parameter(Mandatory)][int]$HedefGorselKolon)
    # winget'in kendi çıktısı, sütunları GÖRSEL genişliğe göre hizalar (CJK karakter = 2 sütun).
    # Sabit karakter indeksiyle kesmek bu satırlarda kaymaya yol açar; bu fonksiyon
    # hedeflenen görsel sütuna karşılık gelen doğru KARAKTER indeksini bulur.
    $gorselToplam = 0
    for ($i = 0; $i -lt $Satir.Length; $i++) {
        if ($gorselToplam -ge $HedefGorselKolon) { return $i }
        $genislik = if (Test-GenisKarakter $Satir[$i]) { 2 } else { 1 }
        $gorselToplam += $genislik
    }
    return $Satir.Length
}

function Get-GorselGenislik {
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Metin)
    $toplam = 0
    foreach ($c in $Metin.ToCharArray()) {
        $toplam += if (Test-GenisKarakter $c) { 2 } else { 1 }
    }
    return $toplam
}

function Format-GorselKisalt {
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Metin, [Parameter(Mandatory)][int]$MaxGenislik)
    if ((Get-GorselGenislik $Metin) -le $MaxGenislik) { return $Metin }
    $kesIndeks = Convert-GorselKolonaKarakterIndeksi -Satir $Metin -HedefGorselKolon ([math]::Max(0, $MaxGenislik - 1))
    return $Metin.Substring(0, $kesIndeks) + "…"
}

function Format-GorselPad {
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Metin, [Parameter(Mandatory)][int]$HedefGenislik)
    $gorsel = Get-GorselGenislik $Metin
    if ($gorsel -ge $HedefGenislik) { return $Metin }
    return $Metin + (" " * ($HedefGenislik - $gorsel))
}

# ===================== WINGET ARAMA + AYRIŞTIRMA (tekrar kullanılabilir) =====================
function Invoke-WingetAramaAyristir {
    param([Parameter(Mandatory)][string]$Sorgu)

    # ÖNCELİKLİ YOL: Microsoft.WinGet.Client modülü (Find-WinGetPackage) üzerinden
    # YAPILANDIRILMIŞ nesne olarak arama. Bu yol, winget.exe'nin konsola bastığı metnin
    # sütun genişliklerini/boşluk sayısını ayrıştırmaya BAĞIMLI DEĞİLDİR; Microsoft ileride
    # CLI çıktısının görsel biçimini değiştirse bile bu yol bozulmaz.
    if (Get-Module -ListAvailable -Name Microsoft.WinGet.Client) {
        try {
            Import-Module Microsoft.WinGet.Client -ErrorAction Stop
            $paketler = @(Find-WinGetPackage -Query $Sorgu -ErrorAction Stop)
            $sonuclarModul = $paketler | ForEach-Object {
                [PSCustomObject]@{
                    Ad      = "$($_.Name)"
                    Id      = "$($_.Id)"
                    Surum   = "$($_.Version)"
                    Eslesme = ""
                    Kaynak  = "$($_.Source)"
                }
            }
            $hamMesaj = if ($sonuclarModul.Count -eq 0) { "'$Sorgu' icin sonuc bulunamadi." } else { "" }
            return [PSCustomObject]@{ Ham = $hamMesaj; Sonuclar = @($sonuclarModul) }
        } catch {
            Yaz-Log "Find-WinGetPackage basarisiz, metin ayristirma yedegine dusuluyor: $($_.Exception.Message)" 'UYARI'
        }
    }

    # YEDEK YOL: modül yoksa veya Find-WinGetPackage hata verirse eski (CLI metin ayrıştırmalı)
    # yönteme düşülür — böylece modül kurulamayan sistemlerde arama yine çalışmaya devam eder.
    $ham = winget search "$Sorgu" 2>&1 | Out-String
    $satirlar = $ham -split "`r?`n"

    $sepIndex = -1
    for ($i = 0; $i -lt $satirlar.Count; $i++) {
        if ($satirlar[$i] -match '^-{5,}\s*$') { $sepIndex = $i; break }
    }

    $sonuclar = @()

    if ($sepIndex -ge 1) {
        $header = $satirlar[$sepIndex - 1]
        $kolonAdlari = $header -split '\s{2,}' | Where-Object { $_ }

        $konumlar = @()
        $aranan = 0
        foreach ($kol in $kolonAdlari) {
            $idx = $header.IndexOf($kol, $aranan)
            if ($idx -lt 0) { $idx = $aranan }
            $konumlar += $idx
            $aranan = $idx + $kol.Length
        }

        for ($i = $sepIndex + 1; $i -lt $satirlar.Count; $i++) {
            $satir = $satirlar[$i]
            if ([string]::IsNullOrWhiteSpace($satir)) { continue }
            if ($konumlar.Count -lt 2) { continue }

            # Görsel sütun konumlarını, BU satıra özel karakter indekslerine çevir
            # (CJK gibi geniş karakterler yüzünden kayma olmasın diye).
            $karakterKonumlari = @()
            foreach ($gk in $konumlar) {
                $karakterKonumlari += Convert-GorselKolonaKarakterIndeksi -Satir $satir -HedefGorselKolon $gk
            }
            if ($satir.Length -lt $karakterKonumlari[0]) { continue }

            $degerler = @()
            for ($k = 0; $k -lt $karakterKonumlari.Count; $k++) {
                $baslangic = $karakterKonumlari[$k]
                if ($baslangic -ge $satir.Length) { $degerler += ""; continue }
                $uzunluk = if ($k -lt $karakterKonumlari.Count - 1) {
                    [math]::Min($karakterKonumlari[$k + 1] - $baslangic, $satir.Length - $baslangic)
                } else {
                    $satir.Length - $baslangic
                }
                if ($uzunluk -lt 0) { $uzunluk = 0 }
                $degerler += $satir.Substring($baslangic, $uzunluk).Trim()
            }

            if ($degerler.Count -lt 2) { continue }
            $sonuclar += [PSCustomObject]@{
                Ad       = $degerler[0]
                Id       = $degerler[1]
                Surum    = if ($degerler.Count -ge 3) { $degerler[2] } else { "" }
                Eslesme  = if ($degerler.Count -ge 4) { $degerler[3] } else { "" }
                Kaynak   = if ($degerler.Count -ge 5) { $degerler[4] } else { "" }
            }
        }
    }

    return [PSCustomObject]@{ Ham = $ham; Sonuclar = $sonuclar }
}

function Search-App {
    Show-Header "UYGULAMA ARA (winget)"

    $arama = Read-Host "  Aranacak uygulama adi (Iptal icin bos Enter)"
    if ([string]::IsNullOrWhiteSpace($arama)) {
        Write-Host "  Islem iptal edildi." -ForegroundColor $Tema.Soluk
        Wait-User
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

    $aramaSonuc    = Invoke-WingetAramaAyristir -Sorgu $arama
    $sonucRaw      = $aramaSonuc.Ham
    $sonucSatirlari = $aramaSonuc.Sonuclar

    # ===== Sonuç yoksa ve sorgu birden fazla kelimeden oluşuyorsa, ilk kelimeyle tekrar dene =====
    # winget, sorguyu TEK bitişik metin olarak arar (örn. "adobe reader", "Adobe Acrobat Reader"
    # içinde bitişik geçmediği için eşleşmez). Bu yüzden tam ifade sonuç vermezse otomatik olarak
    # ilk kelimeyle geniş bir arama denenir ve kullanıcıya açıkça bildirilir.
    if ($sonucSatirlari.Count -eq 0) {
        $kelimeler = $arama -split '\s+' | Where-Object { $_ }
        if ($kelimeler.Count -gt 1) {
            $ilkKelime = $kelimeler[0]
            Write-Host "  '$arama' icin sonuc bulunamadi." -ForegroundColor $Tema.Soluk
            Write-Host "  (winget, coklu kelimeli sorgularda TEK bitisik metin arar; bu yuzden" -ForegroundColor $Tema.Soluk
            Write-Host "  'Adobe Acrobat Reader' gibi aradaki kelimeleri iceren isimler kacabilir.)" -ForegroundColor $Tema.Soluk
            Write-Host "  Ilk kelimeyle ('$ilkKelime') otomatik olarak tekrar araniyor..." -ForegroundColor $Tema.Vurgu
            Write-Host ""

            $aramaSonuc     = Invoke-WingetAramaAyristir -Sorgu $ilkKelime
            $sonucRaw       = $aramaSonuc.Ham
            $sonucSatirlari = $aramaSonuc.Sonuclar

            if ($sonucSatirlari.Count -gt 0) {
                Write-Host "  Not: Asagidaki sonuclar '$ilkKelime' icin listeleniyor;" -ForegroundColor $Tema.Soluk
                Write-Host "  '$arama' ifadesinin tamamiyla tam eslesme bulunamadi." -ForegroundColor $Tema.Soluk
                Write-Host ""
            }
        }
    }

    Write-Host ""

    if ($sonucSatirlari.Count -eq 0) {
        # Ayrıştırma başarısız olduysa (örn. "sonuç bulunamadı" mesajı) ham metni göster
        Write-Host $sonucRaw.Trim() -ForegroundColor $Tema.Metin
    } else {
        # ===== Gerçek konsol genişliğine göre dinamik sütun genişlikleri =====
        $konsolGenislik = 100
        try {
            $g = [Console]::WindowWidth
            if ($g -gt 20) { $konsolGenislik = $g }
        } catch {}
        if ($konsolGenislik -gt 200) { $konsolGenislik = 200 }

        $idGenMax      = ($sonucSatirlari | ForEach-Object { Get-GorselGenislik $_.Id }      | Measure-Object -Maximum).Maximum
        $surumGenMax   = ($sonucSatirlari | ForEach-Object { Get-GorselGenislik $_.Surum }   | Measure-Object -Maximum).Maximum
        $eslesmeGenMax = ($sonucSatirlari | ForEach-Object { Get-GorselGenislik $_.Eslesme } | Measure-Object -Maximum).Maximum
        $kaynakGenMax  = ($sonucSatirlari | ForEach-Object { Get-GorselGenislik $_.Kaynak }  | Measure-Object -Maximum).Maximum

        $idGen      = [math]::Min([math]::Max($idGenMax, 2), 40)
        $surumGen   = [math]::Min([math]::Max($surumGenMax, 3), 14)
        $eslesmeGen = [math]::Min([math]::Max($eslesmeGenMax, 5), 22)
        $kaynakGen  = [math]::Min([math]::Max($kaynakGenMax, 6), 10)

        # Kalan alanın tamamı Ad (isim) sütununa ayrılır (Sağdaki kaymayı önlemek için -14 yapıldı)
        $adGen = $konsolGenislik - $idGen - $surumGen - $eslesmeGen - $kaynakGen - 14
        if ($adGen -lt 12) { $adGen = 12 }

        # "Kaynak" başlığının da uzunluk hesabı için PadRight eklendi
        $baslikSatiri = "  " + "Ad".PadRight($adGen) + "  " + "Id".PadRight($idGen) + "  " + "Sürüm".PadRight($surumGen) + "  " + "Eşleşme".PadRight($eslesmeGen) + "  " + "Kaynak".PadRight($kaynakGen)
        Write-Host $baslikSatiri -ForegroundColor $Tema.Baslik
        
        # Ayracı pencere sınırına kadar uzatmak yerine, tam olarak yazılarla aynı boyda bitiriyoruz
        $cizgiUzunluk = $adGen + $idGen + $surumGen + $eslesmeGen + $kaynakGen + 8
        Write-Host ("  " + ("─" * $cizgiUzunluk)) -ForegroundColor $Tema.Soluk

        foreach ($r in $sonucSatirlari) {
            # Hem kısaltma hem hizalama, karakter SAYISI değil GÖRSEL GENİŞLİK esas alınarak yapılır;
            # aksi halde CJK gibi geniş karakter içeren satırlarda sütunlar yine kayar.
            $adGoster      = Format-GorselPad -Metin (Format-GorselKisalt -Metin $r.Ad      -MaxGenislik $adGen)      -HedefGenislik $adGen
            $idGoster      = Format-GorselPad -Metin (Format-GorselKisalt -Metin $r.Id      -MaxGenislik $idGen)      -HedefGenislik $idGen
            $surumGoster   = Format-GorselPad -Metin (Format-GorselKisalt -Metin $r.Surum   -MaxGenislik $surumGen)   -HedefGenislik $surumGen
            $eslesmeGoster = Format-GorselPad -Metin (Format-GorselKisalt -Metin $r.Eslesme -MaxGenislik $eslesmeGen) -HedefGenislik $eslesmeGen

            Write-Host ("  " + $adGoster + "  " + $idGoster + "  " + $surumGoster + "  " + $eslesmeGoster + "  " + $r.Kaynak) -ForegroundColor $Tema.Metin
        }
    }
    Write-Host ""

    if ($storeVar) {
        Write-Host "  Bilgi: Store mevcut. Tum paketler kurulabilir." -ForegroundColor $Tema.Soluk
    }
    Write-Host ""

    $id = Read-Host "  Kurmak icin uygulama ID'sini yazin (atlamak icin bos Enter)"
    if ([string]::IsNullOrWhiteSpace($id)) {
        Write-Host "  Kurulum atlandi." -ForegroundColor $Tema.Soluk
        Wait-User
        return
    }
    $id = $id.Trim()

    # Ad'ı ham metinden regex ile değil, doğrudan ayrıştırılmış (yapılandırılmış)
    # satırlardan bulur — bu, benzer ID'lerin yanlış eşleşmesini de önler.
    $secilenAd = $id
    $eslesen = $sonucSatirlari | Where-Object { $_.Id -eq $id } | Select-Object -First 1
    if ($eslesen) { $secilenAd = $eslesen.Ad }

    Write-Host ""
    Write-Host "  '$secilenAd' kuruluyor..." -ForegroundColor $Tema.Vurgu
    Write-Host ""

    winget install --id "$id" --accept-package-agreements --accept-source-agreements

    if ($LASTEXITCODE -eq -2147023143) {
        Write-Host "  Firewall servisi kapali. Baslatiliyor..." -ForegroundColor $Tema.Hata
        Start-Service BFE, mpssvc, Winmgmt -ErrorAction SilentlyContinue
        Write-Host "  Tekrar deneniyor..." -ForegroundColor $Tema.Vurgu
        winget install --id "$id" --accept-package-agreements --accept-source-agreements
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
    Wait-User
}

function App-ExportImport {
    Show-Header "UYGULAMA LİSTESİ DIŞA/İÇE AKTAR"
    Write-Host "  1) Yüklü uygulama listesini dışa aktar" -ForegroundColor White
    Write-Host "  2) Dosyadan uygulamaları içe aktar (kur)" -ForegroundColor White
    Write-Host "  0) Ana menüye dön" -ForegroundColor $Tema.Soluk
    Write-Host ""

    if (-not $WingetVar) {
        Write-Result $false "Winget bulunamadı, bu işlem yapılamıyor."
        Wait-User
        return
    }

    $sec = Read-Host "  Seçiminiz"
    if ($sec -eq "0") { return }

    if ($sec -eq "1") {
        $hedef = Select-Folder "Listenin kaydedileceği klasörü seçin"
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
        $dosya = Select-File "Uygulama Listesi (*.json)|*.json|Tüm Dosyalar (*.*)|*.*"
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
                Write-Result $false "Seçilen dosya geçerli değil veya boş. İşlem durduruldu."
                Wait-User
                return
            }

            $onay = Read-Host "  '$dosya' içindeki uygulamalar kurulacak. Onaylıyor musunuz? (E/H)"
            if ($onay -eq "E" -or $onay -eq "e") {

                Write-Host ""
                Write-Host "  Lütfen bekleyin, uygulamalar kuruluyor (canlı akacak)..." -ForegroundColor $Tema.Soluk
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
    Wait-User
}
function Test-WingetPaketYuklu {
    # Bir paketin yüklü olup olmadığını kontrol eder. ÖNCE Microsoft.WinGet.Client modülünü
    # (Get-WinGetPackage) dener — bu, "winget list" çıktısını metin olarak arayıp Escape edilmiş
    # ID/Ad'ın satır içinde geçip geçmediğine bakmaktan çok daha güvenilirdir (Microsoft konsol
    # tablosunun sütun/boşluk biçimini değiştirirse metin araması bozulabilir). Modül yoksa veya
    # hata verirse eski metin tabanlı yönteme düşer.
    param([string]$HedefIdVeyaAd)

    if (Get-Module -ListAvailable -Name Microsoft.WinGet.Client) {
        try {
            Import-Module Microsoft.WinGet.Client -ErrorAction Stop
            $paket = Get-WinGetPackage -Id $HedefIdVeyaAd -ErrorAction SilentlyContinue
            if (-not $paket) { $paket = Get-WinGetPackage -Name $HedefIdVeyaAd -ErrorAction SilentlyContinue }
            return ($null -ne $paket)
        } catch {
            Yaz-Log "Get-WinGetPackage basarisiz, metin ayristirma yedegine dusuluyor: $($_.Exception.Message)" 'UYARI'
        }
    }

    $ciktiId = (winget list --id $HedefIdVeyaAd 2>$null | Out-String)
    if ($ciktiId -match [regex]::Escape($HedefIdVeyaAd)) { return $true }
    $ciktiAd = (winget list --name $HedefIdVeyaAd 2>$null | Out-String)
    return [bool]($ciktiAd -match [regex]::Escape($HedefIdVeyaAd))
}

function App-Uninstall {
    Show-Header "UYGULAMA KALDIR"
    Write-Host "  Yüklü tüm uygulamalar listeleniyor..." -ForegroundColor $Tema.Uyari
    Write-Host ""
    if (-not $WingetVar) {
        Write-Result $false "Winget bulunamadı."
        Wait-User
        return
    }
    winget list
    Write-Host ""
    Write-Host "  Yukarıdaki listeden kaldırmak istediğiniz uygulamanın" -ForegroundColor $Tema.Bilgi
    Write-Host "  ID veya Ad bilgisini girin (boş bırakıp Enter = iptal)." -ForegroundColor $Tema.Bilgi
    Write-Host ""
    $hedef = Read-Host "  Kaldırılacak uygulama (ID veya Ad)"
    if ([string]::IsNullOrWhiteSpace($hedef)) {
        Write-Result $false "İşlem iptal edildi."
        Wait-User; return
    }

    $gercekAd = $hedef

    if (-not (Confirm-YoksaIptal "'$hedef' kaldırılsın mı?")) { return }

    try {
        $varOncesiId = Test-WingetPaketYuklu -HedefIdVeyaAd $hedef

        $ciktiId = (winget uninstall --id $hedef --silent --accept-source-agreements 2>&1 | Out-String)
        $kod = $LASTEXITCODE
        $ciktiTum = $ciktiId

        if ($kod -ne 0) {
            Write-Host "  ID ile bulunamadı, Ad ile deneniyor..." -ForegroundColor $Tema.Soluk
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
        $halaVar = Test-WingetPaketYuklu -HedefIdVeyaAd $hedef

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
    Wait-User
}
# ===================== UYGULAMA ARA / KALDIR ALT MENÜSÜ =====================
function Invoke-AramaKaldirMenusu {
    while ($true) {
        Clear-Host
        Show-Header "UYGULAMA ARA / KALDIR"

        Write-Host "  Lütfen yapmak istediğiniz işlemi seçin:" -ForegroundColor $Tema.Metin
        Write-Host ""
        Write-Host "  [1] Uygulama Ara ve Kur (winget)" -ForegroundColor $Tema.Vurgu
        Write-Host "  [2] Uygulama Kaldır" -ForegroundColor $Tema.Vurgu
        Write-Host "  [0] Ana Menüye Dön" -ForegroundColor $Tema.Soluk
        Write-Host ""

        $secim = Read-Host "  Seçiminiz"

        switch ($secim) {
            "1" { Search-App }
            "2" { App-Uninstall }
            "0" { return }
            default {
                Write-Host "  Geçersiz seçim. Lütfen tekrar deneyin." -ForegroundColor $Tema.Hata
                Start-Sleep -Seconds 2
            }
        }
    }
}
function Show-Help {
    Show-Header "YARDIM / HAKKINDA"
    Write-Host "  Bilgisayar Aracı" -ForegroundColor $Tema.Vurgu
    Write-Host "  Hazırlayan : Mehmet IŞIK" -ForegroundColor $Tema.Metin
    Write-Host "  Güncelleme : 15.07.2026" -ForegroundColor $Tema.Metin
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
            # NOT: Önceden burada "$_ -ne 16" ile Alpemix numaraya göre hariç tutuluyordu.
            # Uygulama listesine yeni satır eklenip Alpemix'in No'su değişirse bu mantık
            # kırılırdı. Bunun yerine dizideki Id="ALPEMIX_OZEL" işaretine göre filtreleniyor.
            $secilenUygulamalar = $Uygulamalar | Where-Object { $secilenNolar -contains $_.No }
            $wingetGerekli = $secilenUygulamalar | Where-Object { $_.Id -ne "ALPEMIX_OZEL" }

            if ($wingetGerekli -and -not $WingetVar) {
                Write-Host ""
                Write-Result $false "Winget kurulu olmadığı için uygulama kurulumu yapılamıyor."
                Write-Host ""
                Write-Host "  Winget'i kurmak için ana menü > 22) Yardım bölümünü kullanın" -ForegroundColor $Tema.Uyari
                Write-Host "  veya programı yeniden başlatın (açılışta otomatik kurulmayı dener)." -ForegroundColor $Tema.Uyari
                Wait-User
                continue   
            }
        }

        if ($sec -eq "H" -or $sec -eq "h") {
            foreach ($u in $Uygulamalar) {
                Install-App $u.Ad $u.Id $u.Kaynak
            }
            Write-Host ""; Wait-User
        }
        elseif ($sec -eq "T" -or $sec -eq "t" -or $sec -match "[0-9]") {
            $numaralar = $sec -split "[,\s]+" | Where-Object { $_ -match "^\d+$" }
            foreach ($n in $numaralar) {
                $secilen = $Uygulamalar | Where-Object { $_.No -eq [int]$n }
                if ($secilen) {
                    Install-App $secilen.Ad $secilen.Id $secilen.Kaynak
                }
            }
            Write-Host ""; Wait-User
        }
    }
}
# ===================== TEMİZLİK ALT MENÜSÜ =====================
function Invoke-TemizlikMenusu {
    while ($true) {
        Clear-Host
        Show-Header "SİSTEM TEMİZLİĞİ VE OPTİMİZASYON"

        Write-Host "  Lütfen yapmak istediğiniz işlemi seçin:" -ForegroundColor $Tema.Metin
        Write-Host ""
        Write-Host "  [1] Standart Disk Temizliği (Windows Cleanmgr - Önerilen)" -ForegroundColor $Tema.Vurgu
        Write-Host "  [2] Derin Sistem Temizliği (Temp, Log, Çöp Kutusu, Update, GPU vb.)" -ForegroundColor $Tema.Vurgu
        Write-Host "  [0] Ana Menüye Dön" -ForegroundColor $Tema.Soluk
        Write-Host ""

        $secim = Read-Host "  Seçiminiz"

	switch ($secim) {
            "1" { Clean-Disk }
            "2" { Clean-Temp }
            "0" { return }
            default { 
                Write-Host "  Geçersiz seçim. Lütfen tekrar deneyin." -ForegroundColor $Tema.Hata
                Start-Sleep -Seconds 2
            }
        }
        
        if ($script:AnaMenuyeDon) {
            return
        }
    }
}
# ===================== TEK DÜZ MENÜ (FLAT) =====================

$Menu = @(
    # ===== SOL SÜTUN =====
    @{ No = 1;  Grup = "UYGULAMA";  Ad = "Uygulama Kurulumu (liste)";        Eylem = { Invoke-AppMenu } }
    @{ No = 2;  Grup = "UYGULAMA";  Ad = "Uygulamaları Güncelle";            Eylem = { Update-AllApps } }
    @{ No = 3;  Grup = "UYGULAMA";  Ad = "Uygulama Ara / Kaldır";            Eylem = { Invoke-AramaKaldirMenusu } }
    @{ No = 4;  Grup = "UYGULAMA";  Ad = "Uygulama Listesi Dışa/İçe Aktar";  Eylem = { App-ExportImport } }

    @{ No = 5; Grup = "BAKIM";     Ad = "Sistem ve Disk Onarımı";            Eylem = { Repair-Disk } }
    @{ No = 6; Grup = "BAKIM";     Ad = "Disk Temizle ve Dönüştür-GPT/MBR";  Eylem = { Reset-DiskTablosu } }
    @{ No = 7; Grup = "BAKIM";     Ad = "Güvenli USB Oluştur (Korumalı)";    Eylem = { Protect-USB } }
    @{ No = 8; Grup = "BAKIM";     Ad = "Windows Güncellemelerini Tara";     Eylem = { Start-WindowsUpdate } }
    @{ No = 9; Grup = "BAKIM";     Ad = "Ağ Ayarlarını Sıfırla";             Eylem = { Reset-Network } }
    @{ No = 10; Grup = "BAKIM";     Ad = "Geri Yükleme Noktası Oluştur";     Eylem = { New-RestorePoint } }

    # ===== SAĞ SÜTUN =====
    @{ No = 11;  Grup = "TEMİZLİK";  Ad = "Sistem Temizliği";                Eylem = { Invoke-TemizlikMenusu } }
    @{ No = 12; Grup = "TEMİZLİK";     Ad = "Yazıcı Kuyruğunu Temizle";      Eylem = { Clear-PrintQueue } }

    @{ No = 13;  Grup = "SÜRÜCÜ";    Ad = "Sürücü Yönetimi";                 Eylem = { Invoke-SurucuMenusu } }

    @{ No = 14; Grup = "BİLGİ";     Ad = "Sistem Bilgileri";                 Eylem = { Invoke-BilgiMenusu } }

    @{ No = 15; Grup = "DİĞER";     Ad = "Yönetim Klasörleri Oluştur";       Eylem = { New-AdminFolders } }
    @{ No = 16; Grup = "DİĞER";     Ad = "Yardım / Hakkında";                Eylem = { Show-Help } }
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
    Show-CenteredLine "💻  B İ L G İ S A Y A R   A R A C I  💻" $Tema.Vurgu

    # 3. İç Ayraç (Başlık ile Slogan arası ince çizgi)
    Show-CenteredLine ("─" * ($BoxWidth - 6)) $Tema.Soluk

    # 4. Slogan
    Show-CenteredLine "Kur • Güncelle • Temizle • Yedekle • Onar" $Tema.Soluk

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

    # NOT: Daha önce burada ham Write-Host + .Substring(0, $BoxWidth) kullanılıyordu.
    # $durum içindeki 💽 / 🧠 gibi surrogate-pair emojiler yüzünden, disk/RAM
    # değerleri belirli bir uzunluğa denk geldiğinde Substring bir karakterin
    # ortasından kesip ArgumentOutOfRangeException fırlatabiliyordu. Show-Line
    # zaten grapheme bazlı ve genişlik-güvenli kesme yaptığı için aynı sorunu
    # yaşamıyor; bu yüzden durum satırını da onun üzerinden basıyoruz.
    Show-Line $durum $Tema.Basari
    Write-Host ("╟" + ("─" * $BoxWidth) + "╢") -ForegroundColor $Tema.Cerceve
    
    # ===== İKONLU GRUP DAĞILIMI =====
    $ikon = @{
        "UYGULAMA" = "📦"; "BİLGİ" = "ℹ️ "; "TEMİZLİK" = "🧹"
        "BAKIM"    = "🔧"; "SÜRÜCÜ" = "💾"; "DİĞER"    = "⚙️ "
    }
    $solGruplar = @("UYGULAMA","BAKIM" )
    $sagGruplar = @("TEMİZLİK", "SÜRÜCÜ", "BİLGİ", "DİĞER")

    $solKolon = Get-Kolon -Gruplar $solGruplar -Ikon $ikon -MenuListesi $Menu
    $sagKolon = Get-Kolon -Gruplar $sagGruplar -Ikon $ikon -MenuListesi $Menu

    $satirSayisi = [math]::Max($solKolon.Count, $sagKolon.Count)
    $kolGenislik = [math]::Floor(($BoxWidth - 1) / 2)
    $sagGen = $BoxWidth - $kolGenislik - 1

    for ($i = 0; $i -lt $satirSayisi; $i++) {
        $solSatir = if ($i -lt $solKolon.Count) { $solKolon[$i] } else { $null }
        $sagSatir = if ($i -lt $sagKolon.Count) { $sagKolon[$i] } else { $null }

        Write-Host "║" -ForegroundColor $Tema.Cerceve -NoNewline
        Write-MenuHucre -Satir $solSatir -Genislik $kolGenislik
        Write-Host "│" -ForegroundColor $Tema.Cerceve -NoNewline
        Write-MenuHucre -Satir $sagSatir -Genislik $sagGen
        Write-Host "║" -ForegroundColor $Tema.Cerceve
    }

# ===== ALT BANT =====
    Write-Host ("╟" + ("─" * $BoxWidth) + "╢") -ForegroundColor $Tema.Cerceve

    if (-not $script:WTKurulu) {
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
# ANA MENÜ AÇILMADAN ÖNCE WINGET MODÜLÜNÜ SESSİZCE HAZIRLA
if ($WingetVar -and -not (Get-Module -ListAvailable -Name Microsoft.WinGet.Client)) {
    Write-Host "  Gerekli yönetim modülleri arka planda hazırlanıyor, lütfen bekleyin..." -ForegroundColor $Tema.Soluk
    Assert-WinGetModulu | Out-Null
}
$cikis = $false
do {
    $script:AnaMenuyeDon = $false
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
                Write-Host "  Geçersiz numara: $sec" -ForegroundColor $Tema.Hata
                Start-Sleep -Milliseconds 900
            }
        }
        else {
            Write-Host ""
            Write-Host "  Lütfen geçerli bir numara girin." -ForegroundColor $Tema.Hata
            Start-Sleep -Milliseconds 900
        }
    }
    catch {
        [Console]::CursorVisible = $true
        Write-Host ""
        Write-Host "  İŞLEM SIRASINDA HATA OLUŞTU:" -ForegroundColor $Tema.Hata
        Write-Host ("  " + $_.Exception.Message) -ForegroundColor $Tema.Hata
        Wait-User
    }
} while (-not $cikis)

Clear-Host
Write-Host "Program kapatıldı. İyi günler, Mehmet IŞIK!" -ForegroundColor $Tema.Bilgi
