# ===================== GLOBAL HATA YAKALAYICI (en başa) =====================
$ErrorActionPreference = "Continue"
$GlobalLog = "$env:USERPROFILE\Desktop\BA_HATA_LOG.txt"
trap {
    "=== YAKALANAN HATA: $(Get-Date) ===" | Out-File $GlobalLog -Append -Encoding UTF8
    "Mesaj : $($_.Exception.Message)"      | Out-File $GlobalLog -Append -Encoding UTF8
    "Satır : $($_.InvocationInfo.ScriptLineNumber)" | Out-File $GlobalLog -Append -Encoding UTF8
    "Komut : $($_.InvocationInfo.Line.Trim())"      | Out-File $GlobalLog -Append -Encoding UTF8
    "Tam   : $($_ | Out-String)"           | Out-File $GlobalLog -Append -Encoding UTF8
    "" | Out-File $GlobalLog -Append -Encoding UTF8
    Write-Host "HATA yakalandı, masaüstüne kaydedildi: $GlobalLog" -ForegroundColor Red
    Start-Sleep -Seconds 1
    continue
}
 <#
    Uygulama İndirme-Güncelleme-Sürücü Yedek Alma-Temizleme Aracı
    Hazırlayan: Mehmet IŞIK
    Güncelleme: 29.06.2026
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

# ===================== WINGET KURULUM/KONTROL (yukarı taşındı) =====================
# NOT: Bu fonksiyon, AŞAMA 1.5'te çağrıldığı için ondan ÖNCE tanımlanmalı.
function Install-Winget {
    if (Get-Command winget -ErrorAction SilentlyContinue) { return $true }
    Write-Host "Winget bulunamadı, kuruluyor..." -ForegroundColor Yellow
    try {
        $tmp = $env:TEMP
        $vclibs = Join-Path $tmp "vclibs.appx"
        $appinst = Join-Path $tmp "appinst.msixbundle"
        Invoke-WebRequest -Uri "https://aka.ms/Microsoft.VCLibs.x64.14.00.Desktop.appx" -OutFile $vclibs -UseBasicParsing
        Invoke-WebRequest -Uri "https://aka.ms/getwinget" -OutFile $appinst -UseBasicParsing
        Add-AppxPackage -Path $vclibs -ErrorAction SilentlyContinue
        Add-AppxPackage -Path $appinst -ErrorAction SilentlyContinue
        Start-Sleep -Seconds 2
        if (Get-Command winget -ErrorAction SilentlyContinue) {
            Write-Host "Winget başarıyla kuruldu." -ForegroundColor Green
            return $true
        }
    } catch {
        Write-Host "Winget kurulamadı: $($_.Exception.Message)" -ForegroundColor Red
    }
    return $false
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

# AŞAMA 1.5: Winget'i garantiye al
$WingetVar = Install-Winget

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
        $genislik = [math]::Min(120, $max.Width)
        $yukseklik = [math]::Min(46, $max.Height)
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
    SeciliBG = "Cyan"
    SeciliFG = "Black"
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
    Show-Line "  ▙▖ BİLGİSAYAR ARACI" $Tema.Soluk
    Show-Line ("  " + $Baslik) $Tema.Vurgu
    Show-Divider
}

function Write-Result {
    param([string]$Mesaj, [bool]$Basari = $true)
    if ($Basari) {
        Write-Host "  " -NoNewline
        Write-Host " ✓ " -ForegroundColor Black -BackgroundColor Green -NoNewline
        Write-Host " " -NoNewline
    } else {
        Write-Host "  " -NoNewline
        Write-Host " ✗ " -ForegroundColor White -BackgroundColor Red -NoNewline
        Write-Host " " -NoNewline
    }
    Write-Host $Mesaj -ForegroundColor $Tema.Metin
}

function Confirm-Islem {
    param([string]$Soru = "Bu işlemi yapmak istediğinize emin misiniz?")
    Write-Host ""
    $cevap = Read-Host "  $Soru (E/H)"
    return ($cevap -eq "E" -or $cevap -eq "e")
}

# ===================== WINGET BİLGİLENDİRME EKRANI =====================
function Show-WingetHelp {
    Show-Header "WINGET (PAKET YÖNETİCİSİ) BULUNAMADI"
    Show-Line "  Bilgisayarınızda Winget yüklü değil." $Tema.Hata
    Show-Bos
    Show-Line "  Winget, Windows 10 (1809+) ve Windows 11'de varsayılan" $Tema.Metin
    Show-Line "  olarak gelen resmi bir paket yöneticisidir. Yüklü değilse" $Tema.Metin
    Show-Line "  aşağıdaki yöntemlerden biriyle kurabilirsiniz." $Tema.Metin
    Show-Divider

    Show-Line "  YÖNTEM 1 — Microsoft Store (Önerilen)" $Tema.Vurgu
    Show-Line "   1) Başlat menüsünden 'Microsoft Store' uygulamasını açın." $Tema.Metin
    Show-Line "   2) Arama çubuğuna 'Uygulama Yükleyici' yazın." $Tema.Metin
    Show-Line "      (İngilizce: 'App Installer')" $Tema.Soluk
    Show-Line "   3) 'Uygulama Yükleyici'yi bulun ve Yükle/Güncelle deyin." $Tema.Metin
    Show-Line "   4) Kurulum bitince winget kullanıma hazır olur." $Tema.Metin
    Show-Bos

    Show-Line "  YÖNTEM 2 — Geliştirici Modu üzerinden" $Tema.Vurgu
    Show-Line "   1) Başlat > 'Ayarlar' uygulamasını açın." $Tema.Metin
    Show-Line "   2) 'Gizlilik ve Güvenlik' > 'Geliştiriciler için' bölümüne gidin." $Tema.Metin
    Show-Line "      (Win 10: 'Güncelleme ve Güvenlik' > 'Geliştiriciler için')" $Tema.Soluk
    Show-Line "   3) 'Geliştirici Modu'nu açın." $Tema.Metin
    Show-Line "   4) Ardından Store'dan 'Uygulama Yükleyici'yi kurun." $Tema.Metin
    Show-Bos

    Show-Line "  YÖNTEM 3 — Otomatik kurulum (bu araç)" $Tema.Vurgu
    Show-Line "   Bu araç açılışta winget'i otomatik kurmayı dener." $Tema.Metin
    Show-Line "   Başarısız olduysa internet bağlantınızı kontrol edip" $Tema.Metin
    Show-Line "   programı yeniden başlatın." $Tema.Metin
    Show-Bottom
    Write-Host ""

    # Kullanıcıyı doğrudan Store'a yönlendirme seçeneği
    $ac = Read-Host "  Microsoft Store'da 'Uygulama Yükleyici' sayfasını açmak ister misiniz? (E/H)"
    if ($ac -eq "E" -or $ac -eq "e") {
        try {
            Start-Process "ms-windows-store://pdp/?productid=9NBLGGH4NNS1" -ErrorAction Stop
            Write-Result "Microsoft Store açıldı (Uygulama Yükleyici sayfası)." $true
        } catch {
            try {
                Start-Process "ms-windows-store://search/?query=Uygulama Yükleyici" -ErrorAction Stop
                Write-Result "Microsoft Store arama sayfası açıldı." $true
            } catch {
                Write-Result "Microsoft Store açılamadı: $($_.Exception.Message)" $false
            }
        }
    } else {
        Write-Result "Store açılmadı. Winget'i daha sonra kurabilirsiniz." $true
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

# ===================== UYGULAMA LİSTESİ (dizi — sıra %100 korunur) =====================

$Uygulamalar = @(
    @{ No = 1;  Ad = "Google Chrome";            Id = "Google.Chrome" }
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
        Write-Result "$Ad kurulamadı: winget bulunamadı." $false
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
        0           { Write-Result "$Ad başarıyla kuruldu." $true }
        -1978335189 { Write-Result "$Ad zaten güncel / yüklü." $true }
        default     { Write-Result "$Ad kurulamadı (Kod: $($sonuc.ExitCode))." $false }
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
            Write-Result "Alpemix indirilemedi." $false
            return
        }
        $boyutKB = [math]::Round((Get-Item $hedef).Length / 1KB, 1)
        if ($boyutKB -lt 50) {
            Write-Result "İndirilen dosya bozuk görünüyor ($boyutKB KB). İptal edildi." $false
            Remove-Item $hedef -Force -ErrorAction SilentlyContinue
            return
        }
        Write-Result "Alpemix indirildi: $hedef ($boyutKB KB)" $true

        $imza = Get-AuthenticodeSignature $hedef
        $imzaGuvenli = $false
        switch ($imza.Status) {
            "Valid" {
                $imzaci = $imza.SignerCertificate.Subject
                Write-Result "Dijital imza GEÇERLİ." $true
                Write-Host ("       İmzalayan: " + $imzaci) -ForegroundColor DarkGray
                $imzaGuvenli = $true
            }
            "NotSigned" {
                Write-Result "UYARI: Dosya dijital olarak İMZALANMAMIŞ." $false
            }
            default {
                Write-Result ("UYARI: İmza durumu güvensiz: " + $imza.Status) $false
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
            Write-Result "Alpemix başlatıldı." $true
        } else {
            Write-Result "Çalıştırma iptal edildi. Dosya masaüstünde duruyor." $true
        }
    } catch {
        Write-Result "Alpemix indirilemedi: $($_.Exception.Message)" $false
    }
}

# ===================== TÜM UYGULAMALARI GÜNCELLE =====================
function Update-AllApps {
    Show-Header "TÜM UYGULAMALARI GÜNCELLE"
    Show-Line "  Sistemde yüklü tüm programlar güncelleniyor..." "Yellow"
    Show-Line "  (winget upgrade --all)" $Tema.Soluk
    Show-Bottom
    Write-Host ""
    if (-not $WingetVar) {
        Write-Result "Winget bulunamadı, güncelleme yapılamıyor." $false
        Write-Host ""
        Read-Host "  Devam etmek için Enter'a basın"
        return
    }

    Write-Host "  Güncellenebilir paketler taranıyor, lütfen bekleyin..." -ForegroundColor DarkGray
    Write-Host ""

    # 1) Güncellenebilir paketleri al (ham liste çıktısı)
    $geciciDosya = Join-Path $env:TEMP "winget_upgrade_list.txt"
    winget upgrade --include-unknown --disable-interactivity `
        --accept-source-agreements 2>&1 |
        Out-File -FilePath $geciciDosya -Encoding UTF8

    $satirlar = @()
    if (Test-Path $geciciDosya) { $satirlar = Get-Content $geciciDosya }
    Remove-Item $geciciDosya -ErrorAction SilentlyContinue

    # 2) Tablo başlığını bul ("Id" sütununun başladığı yer) ve Id'leri ayrıştır
    $paketler = @()
    $baslikIndex = -1
    $idBaslangic = -1
    $surumBaslangic = -1

    for ($i = 0; $i -lt $satirlar.Count; $i++) {
        $s = $satirlar[$i]
        # Başlık satırı: hem "Id" hem sürüm sütunu geçer (TR: "Sürüm", EN: "Version")
        if ($s -match '\bId\b' -and ($s -match 'Version' -or $s -match 'Sürüm' -or $s -match 'Surum')) {
            $baslikIndex = $i
            $idBaslangic = $s.IndexOf("Id")
            # Sürüm sütununun başlangıcı (Id'den sonraki kolon)
            $m = [regex]::Match($s, 'Version|Sürüm|Surum')
            if ($m.Success) { $surumBaslangic = $m.Index }
            break
        }
    }

    if ($baslikIndex -ge 0 -and $idBaslangic -ge 0 -and $surumBaslangic -gt $idBaslangic) {
        # Başlıktan sonraki satırları işle (ayraç "---" satırını atla)
        for ($i = $baslikIndex + 1; $i -lt $satirlar.Count; $i++) {
            $satir = $satirlar[$i]
            if ([string]::IsNullOrWhiteSpace($satir)) { continue }
            if ($satir -match '^[-\s]+$') { continue }            # ayraç çizgisi
            if ($satir -match 'upgrades available') { continue }    # alt bilgi
            if ($satir.Length -lt $surumBaslangic) { continue }     # kısa/geçersiz satır

            # Ad = satır başından Id sütununa kadar; Id = Id sütunundan Sürüm sütununa kadar
            $ad = $satir.Substring(0, $idBaslangic).Trim()
            $id = $satir.Substring($idBaslangic, $surumBaslangic - $idBaslangic).Trim()

            if (-not [string]::IsNullOrWhiteSpace($id) -and -not [string]::IsNullOrWhiteSpace($ad)) {
                $paketler += [PSCustomObject]@{ Ad = $ad; Id = $id }
            }
        }
    }

    $toplam = $paketler.Count

    # 3) Hiç güncelleme yoksa
    if ($toplam -eq 0) {
        Write-Host ""
        Show-Top
        Show-Line "  GÜNCELLEME ÖZETİ" $Tema.Vurgu
        Show-Divider
        Show-Line "  Tüm uygulamalar zaten güncel." $Tema.Basari
        Show-Bottom
        Write-Host ""
        Write-Result "Tüm uygulamalar zaten güncel — güncelleme gerekmedi." $true
        Write-Host ""
        Read-Host "  Devam etmek için Enter'a basın"
        return
    }

    # 4) Bulunan paketleri tek tek güncelle ([X/N] sayaçlı)
    Write-Result "$toplam paket güncellenecek." $true
    Write-Host ""

    $basarili  = 0
    $basarisiz = 0
    $sira = 0

    foreach ($p in $paketler) {
        $sira++
        Write-Host ("  [$sira/$toplam] " + $p.Ad + " güncelleniyor...") -ForegroundColor $Tema.Metin -NoNewline

        # Paketi sessizce güncelle (çıktı ekrana dökülmez)
        $sonuc = Start-Process winget -ArgumentList @(
            "upgrade", "--id", $p.Id, "--silent", "--disable-interactivity",
            "--accept-package-agreements", "--accept-source-agreements"
        ) -Wait -PassThru -NoNewWindow

        if ($sonuc.ExitCode -eq 0) {
            Write-Host "  ✓" -ForegroundColor $Tema.Basari
            $basarili++
        } else {
            Write-Host "  ✗ (Kod: $($sonuc.ExitCode))" -ForegroundColor $Tema.Hata
            $basarisiz++
        }
    }

    # 5) ÖZET KUTUSU
    Write-Host ""
    Show-Top
    Show-Line "  GÜNCELLEME ÖZETİ" $Tema.Vurgu
    Show-Divider
    Show-Line ("  Toplam işlenen          : " + $toplam + " uygulama") $Tema.Baslik
    Show-Line ("  Başarıyla güncellenen   : " + $basarili + " uygulama") $Tema.Basari
    if ($basarisiz -gt 0) {
        Show-Line ("  Başarısız olan          : " + $basarisiz + " uygulama") $Tema.Hata
    } else {
        Show-Line ("  Başarısız olan          : 0 uygulama") $Tema.Soluk
    }
    Show-Bottom
    Write-Host ""

    if ($basarisiz -eq 0) {
        Write-Result "$basarili uygulama başarıyla güncellendi." $true
    } else {
        Write-Result "$basarili güncellendi, $basarisiz başarısız oldu." $false
    }

    Write-Host ""
    Read-Host "  Devam etmek için Enter'a basın"
}
# ===================== SİSTEM FONKSİYONLARI =====================

function New-AdminFolders {
    Show-Header "YÖNETİM KLASÖRLERİ OLUŞTUR"
    Write-Host ""
    $onay = Read-Host "  Masaüstünde Admin ve GodMode klasörleri oluşturulsun mu? (E/H)"
    if ($onay -ne "E" -and $onay -ne "e") {
        Write-Result "İşlem iptal edildi." $false; Write-Host ""; Read-Host "  Devam etmek için Enter'a basın"; return
    }
    $masaustu = [Environment]::GetFolderPath("Desktop")
    try {
        $adminYol   = Join-Path $masaustu "Yönetim Araçları.{D20EA4E1-3957-11d2-A40B-0C5020524153}"
        $godmodeYol = Join-Path $masaustu "GodMode.{ED7BA470-8E54-465E-825C-99712043E01C}"
        if (-not (Test-Path $adminYol))   { New-Item -Path $adminYol -ItemType Directory -Force | Out-Null }
        if (-not (Test-Path $godmodeYol)) { New-Item -Path $godmodeYol -ItemType Directory -Force | Out-Null }
        Write-Result "Yönetim ve GodMode klasörleri masaüstünde oluşturuldu." $true
    } catch {
        Write-Result "Klasör oluşturulamadı: $($_.Exception.Message)" $false
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
        $ram = [math]::Round($cs.TotalPhysicalMemory / 1GB, 1)
        Show-Line ("  Bilgisayar : " + $cs.Name) $Tema.Baslik
        Show-Line ("  İşletim S. : " + $os.Caption) $Tema.Baslik
        Show-Line ("  Sürüm      : " + $os.Version) $Tema.Metin
        Show-Line ("  İşlemci    : " + $cpu.Name.Trim()) $Tema.Metin
        Show-Line ("  RAM        : " + $ram + " GB") $Tema.Metin
        Show-Line ("  Üretici    : " + $cs.Manufacturer) $Tema.Metin
    } catch {
        Show-Line ("  Bilgi alınamadı: " + $_.Exception.Message) $Tema.Hata
    }
    Show-Bottom
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
            Show-Line ("  Sürücü " + $_.DeviceID + "  Toplam: $toplam GB  Boş: $bos GB  (%$yuzde dolu)") $Tema.Baslik
        }
    } catch {
        Show-Line ("  Disk bilgisi alınamadı.") $Tema.Hata
    }
    Show-Bottom
    Write-Host ""
    Read-Host "  Devam etmek için Enter'a basın"
}

function Show-DiskHealth {
    Show-Header "DİSK SAĞLIĞI (SMART)"
    try {
        Get-PhysicalDisk | ForEach-Object {
            $durum = $_.HealthStatus
            $renk = if ($durum -eq "Healthy") { $Tema.Basari } else { $Tema.Hata }
            Show-Line ("  " + $_.FriendlyName + "  Durum: " + $durum) $renk
        }
    } catch {
        Show-Line ("  Disk sağlık bilgisi alınamadı.") $Tema.Hata
    }
    Show-Bottom
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
            Show-Line ("  " + $_.Name + "  ->  " + $_.Command) $Tema.Metin
        }
        if ($sayac -eq 0) {
            Show-Line "  Kayıtlı başlangıç programı bulunamadı." $Tema.Soluk
        } else {
            Show-Divider
            Show-Line ("  Toplam $sayac başlangıç programı bulundu.") $Tema.Vurgu
        }
    } catch {
        Show-Line "  Başlangıç programları alınamadı." $Tema.Hata
    }

    Show-Bottom
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
            Write-Result "Ayarlar > Başlangıç sayfası açıldı." $true
        } catch {
            try {
                Start-Process "taskmgr.exe" -ArgumentList "/0 /startup" -ErrorAction Stop
                Write-Result "Görev Yöneticisi (Başlangıç sekmesi) açıldı." $true
            } catch {
                Write-Result "Başlangıç ayarları açılamadı: $($_.Exception.Message)" $false
            }
        }
    } else {
        Write-Host ""
        Write-Result "Başlangıç ayarları açılmadı. Ana menüye dönülüyor." $true
    }

    Read-Host "`n  Devam etmek için Enter'a basın"
}

function Start-WindowsUpdate {
    Show-Header "WINDOWS GÜNCELLEMELERİ"
    Write-Host ""
    $onay = Read-Host "  Windows güncellemeleri aranıp kurulsun mu? (E/H)"
    if ($onay -ne "E" -and $onay -ne "e") {
        Write-Result "İşlem iptal edildi." $false; Write-Host ""; Read-Host "  Devam etmek için Enter'a basın"; return
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
        Write-Result "Windows güncelleme işlemi tamamlandı." $true
    } catch {
        Write-Progress -Activity "Windows Update" -Completed
        Write-Result "Güncelleme yapılamadı: $($_.Exception.Message)" $false
    }
    Write-Host ""
    Read-Host "  Devam etmek için Enter'a basın"
}

function Reset-Network {
    Show-Header "AĞ SIFIRLAMA"
    Write-Host ""
if (-not (Confirm-Islem "Ağ ayarları sıfırlanacak (DNS, Winsock, IP). Emin misiniz?")) {
    Write-Result "İşlem iptal edildi." $false
    Write-Host ""; Read-Host "  Devam etmek için Enter'a basın"; return
}

    try {
        ipconfig /flushdns | Out-Null
        netsh winsock reset | Out-Null
        netsh int ip reset | Out-Null
        Write-Result "Ağ ayarları sıfırlandı. Bilgisayarı yeniden başlatın." $true
    } catch {
        Write-Result "Ağ sıfırlanamadı: $($_.Exception.Message)" $false
    }
    Write-Host ""
    Read-Host "  Devam etmek için Enter'a basın"
}

function New-RestorePoint {
    Show-Header "SİSTEM GERİ YÜKLEME NOKTASI"
    Write-Host ""
    $onay = Read-Host "  Sistem geri yükleme noktası oluşturulsun mu? (E/H)"
    if ($onay -ne "E" -and $onay -ne "e") {
        Write-Result "İşlem iptal edildi." $false; Write-Host ""; Read-Host "  Devam etmek için Enter'a basın"; return
    }

try {
        Enable-ComputerRestore -Drive "C:\" -ErrorAction SilentlyContinue
        Checkpoint-Computer -Description "Bilgisayar Araci - $(Get-Date -Format 'yyyy-MM-dd HH:mm')" -RestorePointType "MODIFY_SETTINGS" -ErrorAction Stop
        Write-Result "Geri yükleme noktası oluşturuldu." $true
    } catch {
        Write-Result "Geri yükleme noktası oluşturulamadı: $($_.Exception.Message)" $false
    }

    Write-Host ""
    Read-Host "  Devam etmek için Enter'a basın"
}

function Clear-PrintQueue {
    Show-Header "YAZICI KUYRUĞUNU TEMİZLE"
    Write-Host ""
    $onay = Read-Host "  Yazıcı kuyruğu temizlenecek. Onaylıyor musunuz? (E/H)"
    if ($onay -ne "E" -and $onay -ne "e") {
        Write-Result "İşlem iptal edildi." $false; Write-Host ""; Read-Host "  Devam etmek için Enter'a basın"; return
    }
    try {
        Stop-Service -Name Spooler -Force -ErrorAction SilentlyContinue
        Remove-Item "$env:SystemRoot\System32\spool\PRINTERS\*" -Force -ErrorAction SilentlyContinue
        Start-Service -Name Spooler -ErrorAction SilentlyContinue
        Write-Result "Yazıcı kuyruğu temizlendi." $true
    } catch {
        Write-Result "Yazıcı kuyruğu temizlenemedi: $($_.Exception.Message)" $false
    }
    Write-Host ""
    Read-Host "  Devam etmek için Enter'a basın"
}

function Show-HealthSummary {
    Show-Header "SİSTEM SAĞLIK ÖZETİ"
    try {
        $os  = Get-CimInstance Win32_OperatingSystem
        $cs  = Get-CimInstance Win32_ComputerSystem
        $ram = [math]::Round($cs.TotalPhysicalMemory / 1GB, 1)
        $bosRam = [math]::Round($os.FreePhysicalMemory / 1024 / 1024, 1)
        $cDisk = Get-CimInstance Win32_LogicalDisk -Filter "DeviceID='C:'"
        $cBos = [math]::Round($cDisk.FreeSpace / 1GB, 1)
        $cTop = [math]::Round($cDisk.Size / 1GB, 1)
        $uptime = (Get-Date) - $os.LastBootUpTime

        Show-Line ("  RAM        : " + $ram + " GB  (Boş: " + $bosRam + " GB)") $Tema.Baslik
        Show-Line ("  C: Disk    : " + $cTop + " GB  (Boş: " + $cBos + " GB)") $Tema.Baslik
        Show-Line ("  Çalışma S. : " + $uptime.Days + " gün " + $uptime.Hours + " saat") $Tema.Metin

        $cYuzde = if ($cTop -gt 0) { [math]::Round((($cTop - $cBos) / $cTop) * 100) } else { 0 }
        Show-Divider
        if ($cYuzde -gt 90) { Show-Line "  ⚠ C: sürücüsü neredeyse dolu!" $Tema.Hata }
        elseif ($cYuzde -gt 75) { Show-Line "  ⚠ C: sürücüsünde yer azalıyor." "Yellow" }
        else { Show-Line "  ✓ Disk durumu iyi." $Tema.Basari }

        if ($bosRam -lt 1) { Show-Line "  ⚠ Boş RAM düşük!" $Tema.Hata }
        else { Show-Line "  ✓ RAM durumu iyi." $Tema.Basari }
    } catch {
        Show-Line ("  Sağlık özeti alınamadı: " + $_.Exception.Message) $Tema.Hata
    }
    Show-Bottom
    Write-Host ""
    Read-Host "  Devam etmek için Enter'a basın"
}

# ===================== GÜVENLİK: KORUNAN YOLLAR (bir kez tanımlanır) =====================
$Global:YasakliYollar = @(
    "$env:SystemDrive\",
    "$env:SystemRoot",
    "$env:SystemDrive",
    "C:\",
    "C:\Windows",
    [Environment]::GetFolderPath("Desktop"),
    [Environment]::GetFolderPath("MyDocuments"),
    [Environment]::GetFolderPath("UserProfile")
)

function Test-GuvenliYol {
    param([string]$Yol)
    if ([string]::IsNullOrWhiteSpace($Yol)) { return $false }
    $tam = [System.IO.Path]::GetFullPath($Yol).TrimEnd('\')
    if ($tam.Length -lt 8) { return $false }
    foreach ($y in $Global:YasakliYollar) {
        if ([string]::IsNullOrWhiteSpace($y)) { continue }
        $yTam = [System.IO.Path]::GetFullPath($y).TrimEnd('\')
        if ($tam -ieq $yTam) { return $false }
    }
    if ($tam -imatch "Temp$" -or $tam -imatch "Prefetch$") { return $true }
    return $false
}

# ===================== TEMİZLİK FONKSİYONLARI =====================

function Clean-Temp {
    Show-Header "GEÇİCİ DOSYALARI TEMİZLE"

    $yollar = @(
        @{ Ad = "Kullanıcı Temp (%temp%)"; Yol = "$env:TEMP" }
        @{ Ad = "Windows Temp";            Yol = "$env:SystemRoot\Temp" }
        @{ Ad = "Prefetch";                Yol = "$env:SystemRoot\Prefetch" }
    )

    # NOT: $yasakli ve Test-GuvenliYol artık global olarak yukarıda tanımlı

    Write-Host "  Mevcut boyutlar hesaplanıyor, lütfen bekleyin..." -ForegroundColor DarkGray
    $oncekiBoyut = 0
    foreach ($k in $yollar) {
        if (Test-Path $k.Yol) { $oncekiBoyut += Get-FolderSizeMB $k.Yol }
    }

    foreach ($k in $yollar) {
        if (-not (Test-Path $k.Yol)) {
            Write-Result ($k.Ad + " bulunamadı, atlandı.") $false
            continue
        }
        if (-not (Test-GuvenliYol $k.Yol)) {
            Write-Result ($k.Ad + " GÜVENLİK nedeniyle atlandı: " + $k.Yol) $false
            continue
        }
        Write-Host ("  Temizleniyor: " + $k.Ad) -ForegroundColor Yellow
        Get-ChildItem -Path $k.Yol -Force -ErrorAction SilentlyContinue | ForEach-Object {
            Remove-Item $_.FullName -Recurse -Force -ErrorAction SilentlyContinue
        }
        Write-Result ($k.Ad + " temizlendi.") $true
    }

    Write-Host "  Temizlik sonrası boyutlar hesaplanıyor..." -ForegroundColor DarkGray
    $sonrakiBoyut = 0
    foreach ($k in $yollar) {
        if (Test-Path $k.Yol) { $sonrakiBoyut += Get-FolderSizeMB $k.Yol }
    }
    $kazanc = [math]::Round($oncekiBoyut - $sonrakiBoyut, 2)
    if ($kazanc -lt 0) { $kazanc = 0 }

    Show-Divider
    Write-Result ("Toplam temizlenen alan: $kazanc MB") $true
    Show-Line "  Not: Prefetch silindiği için ilk açılışlar biraz" $Tema.Soluk
    Show-Line "  yavaş olabilir, sonra normale döner." $Tema.Soluk
    Write-Host ""
    Read-Host "  Devam etmek için Enter'a basın"
}

function Clean-Logs {
    Show-Header "WINDOWS LOG DOSYALARINI TEMİZLE"
    Show-Line "  Windows olay günlükleri temizleniyor..." "Yellow"
    Show-Line "  (Bu işlem birkaç dakika sürebilir, lütfen bekleyin.)" $Tema.Soluk
    Show-Bottom
    Write-Host ""
    try {
        # Tüm olay günlüklerinin listesini al
        $loglar = @(wevtutil el)
        $toplam = $loglar.Count
        if ($toplam -eq 0) {
            Write-Result "Temizlenecek olay günlüğü bulunamadı." $false
            Write-Host ""
            Read-Host "  Devam etmek için Enter'a basın"
            return
        }

        $sayac = 0
        $basarili = 0
        foreach ($log in $loglar) {
            $sayac++
            # İlerleme çubuğu (üst kısımda)
            $yuzde = [math]::Round(($sayac / $toplam) * 100)
            Write-Progress -Activity "Olay günlükleri temizleniyor" `
                           -Status "$sayac / $toplam  (%$yuzde)" `
                           -CurrentOperation $log `
                           -PercentComplete $yuzde

            # Günlüğü temizle (hatalar sessiz geçilir; bazı loglar korumalıdır)
            wevtutil cl "$log" 2>$null
            if ($LASTEXITCODE -eq 0) { $basarili++ }
        }
        Write-Progress -Activity "Olay günlükleri temizleniyor" -Completed

        Write-Host ""
        Write-Result "$basarili / $toplam olay günlüğü temizlendi." $true
        if ($basarili -lt $toplam) {
            Show-Line "  Not: Bazı korumalı günlükler temizlenemez (normaldir)." $Tema.Soluk
        }
    } catch {
        Write-Result "Log temizlenemedi: $($_.Exception.Message)" $false
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
        Write-Result "Windows Update önbelleği temizlendi." $true
    } catch {
        Write-Result "Önbellek temizlenemedi: $($_.Exception.Message)" $false
    }
    Write-Host ""
    Read-Host "  Devam etmek için Enter'a basın"
}

function Clean-RecycleBin {
       Show-Top
    Show-Line "  GERİ DÖNÜŞÜM KUTUSU TEMİZLENİYOR" $Tema.Baslik
    Show-Bottom
    Write-Host ""

    try {
        Clear-RecycleBin -Force -ErrorAction Stop
        Write-Host "  ✓  Geri dönüşüm kutusu temizlendi" -ForegroundColor $Tema.Basari
    }
    catch {
        # "Yol bulunamadı" / "zaten boş" hataları aslında BAŞARI demektir
        if ($_.Exception.Message -match "belirtilen yolu bulamıyor" -or
            $_.Exception.Message -match "cannot find the path" -or
            $_.Exception.Message -match "Recycle Bin.*empty" -or
            $_.Exception.Message -match "boş") {
            Write-Host "  ✓  Geri dönüşüm kutusu temizlendi" -ForegroundColor $Tema.Basari
        }
        else {
            # Gerçek bir hata varsa göster
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
        Write-Result "Disk Temizleme aracı çalıştırıldı." $true
    } catch {
        Write-Result "Disk Temizleme çalıştırılamadı: $($_.Exception.Message)" $false
    }
    Write-Host ""
    Read-Host "  Devam etmek için Enter'a basın"
}
function Clean-GpuLeftovers {
    Show-Header "EKRAN KARTI SÜRÜCÜ ARTIKLARINI TEMİZLE"
    Show-Line "  C:\AMD, C:\NVIDIA, C:\INTEL kurulum artıkları silinir." $Tema.Metin
    Show-Line "  (Yüklü sürücüleriniz ETKİLENMEZ — sadece kurulum" $Tema.Soluk
    Show-Line "   dosyaları temizlenir.)" $Tema.Soluk
    Show-Bottom
    Write-Host ""
    $onay = Read-Host "  Devam edilsin mi? (E/H)"
    if ($onay -ne "E" -and $onay -ne "e") {
        Write-Result "İşlem iptal edildi." $false
        Write-Host ""; Read-Host "  Devam etmek için Enter'a basın"; return
    }

    # Yalnızca bu üç köke izin ver — güvenlik için sabit liste
    $hedefler = @(
        (Join-Path $env:SystemDrive "AMD"),
        (Join-Path $env:SystemDrive "NVIDIA"),
        (Join-Path $env:SystemDrive "INTEL")
    )

    $oncekiBoyut = 0
    foreach ($h in $hedefler) {
        if (Test-Path $h) { $oncekiBoyut += Get-FolderSizeMB $h }
    }

    foreach ($h in $hedefler) {
        if (-not (Test-Path $h)) {
            Write-Result ((Split-Path $h -Leaf) + " klasörü yok, atlandı.") $true
            continue
        }
        # GÜVENLİK: yol gerçekten C:\AMD / C:\NVIDIA / C:\INTEL mi?
        $tam = [System.IO.Path]::GetFullPath($h).TrimEnd('\')
        $ad  = (Split-Path $tam -Leaf).ToUpper()
        if (($ad -ne "AMD" -and $ad -ne "NVIDIA" -and $ad -ne "INTEL") -or $tam.Length -lt 6) {
            Write-Result ("GÜVENLİK nedeniyle atlandı: " + $tam) $false
            continue
        }
        Write-Host ("  Temizleniyor: " + $tam) -ForegroundColor Yellow
        Get-ChildItem -Path $h -Force -ErrorAction SilentlyContinue | ForEach-Object {
            Remove-Item $_.FullName -Recurse -Force -ErrorAction SilentlyContinue
        }
        Write-Result ($ad + " kurulum artıkları temizlendi.") $true
    }

    $sonrakiBoyut = 0
    foreach ($h in $hedefler) {
        if (Test-Path $h) { $sonrakiBoyut += Get-FolderSizeMB $h }
    }
    $kazanc = [math]::Round($oncekiBoyut - $sonrakiBoyut, 2)
    if ($kazanc -lt 0) { $kazanc = 0 }

    Show-Divider
    Write-Result ("Toplam temizlenen alan: $kazanc MB") $true
    Write-Host ""
    Read-Host "  Devam etmek için Enter'a basın"
}
function Repair-SystemFiles {
    Show-Header "SİSTEM DOSYALARINI TARA VE ONAR (SFC)"
    Show-Line "  Bozuk Windows sistem dosyaları taranıp onarılır." $Tema.Metin
    Show-Line "  (sfc /scannow — birkaç dakika sürebilir.)" $Tema.Soluk
    Show-Bottom
    Write-Host ""
    $onay = Read-Host "  Tarama başlatılsın mı? (E/H)"
    if ($onay -ne "E" -and $onay -ne "e") {
        Write-Result "İşlem iptal edildi." $false
        Write-Host ""; Read-Host "  Devam etmek için Enter'a basın"; return
    }
    try {
        Write-Host "  Sistem dosyaları taranıyor, lütfen bekleyin..." -ForegroundColor Yellow
        Write-Host ""
        sfc /scannow
        Write-Host ""
        Write-Result "Sistem dosyası taraması tamamlandı." $true
    } catch {
        Write-Result "Tarama yapılamadı: $($_.Exception.Message)" $false
    }
    Write-Host ""
    Read-Host "  Devam etmek için Enter'a basın"
}

# ===================== SÜRÜCÜ VE UYGULAMA YÖNETİMİ =====================

function Backup-Drivers {
    Show-Header "SÜRÜCÜ YEDEKLE"
    $hedef = Select-Folder "Sürücülerin yedekleneceği klasörü seçin"
    if (-not $hedef) { Write-Result "İşlem iptal edildi." $false; Write-Host ""; Read-Host "  Devam etmek için Enter'a basın"; return }

    $klasor = Join-Path $hedef ("Surucu_Yedek_" + (Get-Date -Format "yyyyMMdd_HHmm"))
    Write-Host ""
    $onay = Read-Host "  Sürücüler '$klasor' klasörüne yedeklenecek. Onaylıyor musunuz? (E/H)"
    if ($onay -ne "E" -and $onay -ne "e") {
        Write-Result "İşlem iptal edildi." $false; Write-Host ""; Read-Host "  Devam etmek için Enter'a basın"; return
    }

    $eskiProgress = $ProgressPreference
    $ProgressPreference = 'SilentlyContinue'
    try {
        New-Item -Path $klasor -ItemType Directory -Force | Out-Null

        Write-Host "  Sürücüler yedekleniyor, lütfen bekleyin..." -ForegroundColor Yellow
        Write-Host "  (Her yedeklenen sürücü canlı listelenecek.)" -ForegroundColor DarkGray
        Write-Host ""

        # Export-WindowsDriver her sürücü için bir nesne döndürür.
        # Pipe ile akıtıp her gelen sürücüde sayacı artır + canlı listele.
        $sayac = 0
        Export-WindowsDriver -Online -Destination $klasor -ErrorAction Stop | ForEach-Object {
            $sayac++
            $no = $sayac.ToString().PadLeft(3)
            $ad = Split-Path $_.OriginalFileName -Leaf
            Write-Host ("  [" + $no + "] ") -ForegroundColor Cyan -NoNewline
            Write-Host $ad -ForegroundColor Gray -NoNewline
            Write-Host ("   (" + $_.ClassName + ")") -ForegroundColor DarkGray

            # Üstte ilerleme sayacı (toplam bilinmediği için yalnız adet gösterir)
            Write-Progress -Activity "Sürücüler yedekleniyor" `
                           -Status "$sayac sürücü yedeklendi..." `
                           -CurrentOperation $ad
        }
        Write-Progress -Activity "Sürücüler yedekleniyor" -Completed

        Write-Host ""
        if ($sayac -gt 0) {
            Write-Result "$sayac sürücü yedeklendi: $klasor" $true
        } else {
            Write-Result "Yedeklenecek sürücü bulunamadı." $false
        }
    } catch {
        Write-Result "Sürücü yedeklenemedi: $($_.Exception.Message)" $false
    } finally {
        $ProgressPreference = $eskiProgress
    }
    Write-Host ""
    Read-Host "  Devam etmek için Enter'a basın"
}

function Restore-Drivers {
    Show-Header "SÜRÜCÜ GERİ YÜKLE"
    $kaynak = Select-Folder "Yedeklenmiş sürücü klasörünü seçin"
    if (-not $kaynak) { Write-Result "İşlem iptal edildi." $false; Write-Host ""; Read-Host "  Devam etmek için Enter'a basın"; return }

    Write-Host ""
    $onay = Read-Host "  Sürücüler '$kaynak' klasöründen geri yüklenecek. Emin misiniz? (E/H)"
    if ($onay -ne "E" -and $onay -ne "e") {
        Write-Result "İşlem iptal edildi." $false; Write-Host ""; Read-Host "  Devam etmek için Enter'a basın"; return
    }
    try {
        # .inf var mı kontrol et
        $infVar = Get-ChildItem -Path $kaynak -Filter *.inf -Recurse -ErrorAction SilentlyContinue
        if (-not $infVar) {
            Write-Result "Seçilen klasörde .inf sürücü dosyası bulunamadı." $false
            Write-Host ""
            Read-Host "  Devam etmek için Enter'a basın"
            return
        }

        Write-Host "  Sürücüler yükleniyor, lütfen bekleyin..." -ForegroundColor Yellow
        pnputil /add-driver "$kaynak\*.inf" /subdirs /install
        $kod = $LASTEXITCODE

        # >>> REVİZE: pnputil çıkış kodlarını doğru yorumla
        #   0    = başarılı
        #   259  = ERROR_NO_MORE_ITEMS -> eklenecek YENİ sürücü yok (zaten güncel) — başarı
        #   3010 = başarılı, yeniden başlatma gerekli
        switch ($kod) {
            0 {
                Write-Result "Sürücüler geri yüklendi." $true
            }
            259 {
                Write-Result "Tüm sürücüler zaten güncel — yüklenecek yeni sürücü yoktu." $true
            }
            3010 {
                Write-Result "Sürücüler geri yüklendi. Değişikliklerin tamamlanması için yeniden başlatın." $true
            }
            default {
                Write-Result "Sürücü geri yükleme tamamlandı ancak bazı sürücüler yüklenemedi (Kod: $kod)." $false
            }
        }
    } catch {
        Write-Result "Sürücü geri yüklenemedi: $($_.Exception.Message)" $false
    }
    Write-Host ""
    Read-Host "  Devam etmek için Enter'a basın"
}

function App-ExportImport {
    Show-Header "UYGULAMA LİSTESİ DIŞA/İÇE AKTAR"
    Write-Host "  1) Yüklü uygulama listesini dışa aktar (JSON)" -ForegroundColor White
    Write-Host "  2) JSON dosyasından uygulamaları içe aktar (kur)" -ForegroundColor White
    Write-Host ""

    if (-not $WingetVar) {
        Write-Result "Winget bulunamadı, bu işlem yapılamıyor." $false
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
                Write-Result "Liste dışa aktarıldı: $dosya ($boyutKB KB)" $true
            } else {
                Write-Result "Dışa aktarma başarısız: dosya oluşturulamadı." $false
            }
        } else {
            Write-Result "İşlem iptal edildi." $false
        }
    } elseif ($sec -eq "2") {
        $dosya = Select-File
        if ($dosya) {
            $onay = Read-Host "  '$dosya' içindeki uygulamalar kurulacak. Onaylıyor musunuz? (E/H)"
            if ($onay -eq "E" -or $onay -eq "e") {

                Write-Host ""
                Write-Host "  Lütfen bekleyin, uygulamalar kuruluyor (canlı akacak)..." -ForegroundColor DarkGray
                Write-Host ""

                # Geçici log dosyası — HEM canlı ekrana ak HEM dosyaya yaz (sayım için)
                $geciciDosya = Join-Path $env:TEMP "winget_import_log.txt"

                winget import -i "$dosya" --disable-interactivity `
                    --accept-package-agreements --accept-source-agreements --ignore-unavailable 2>&1 |
                    Tee-Object -FilePath $geciciDosya
                $kod = $LASTEXITCODE

                # Sayım için dosyayı oku
                $ham = ""
                if (Test-Path $geciciDosya) { $ham = Get-Content $geciciDosya -Raw }
                Remove-Item $geciciDosya -ErrorAction SilentlyContinue

                # Sayım (regex ile — en güvenilir)
                $zatenKurulu = ([regex]::Matches($ham, "already installed")).Count
                $yeniKurulan = ([regex]::Matches($ham, "Successfully installed")).Count
                $toplam      = $zatenKurulu + $yeniKurulan

                # >>> ÖZET KUTUSU
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
                        Write-Result "$yeniKurulan uygulama yeni kuruldu, $zatenKurulu uygulama zaten kuruluydu." $true
                    } else {
                        Write-Result "Tüm uygulamalar ($zatenKurulu) zaten kuruluydu — yeni kurulum gerekmedi." $true
                    }
                } else {
                    Write-Result "İçe aktarma tamamlandı ancak bazı uygulamalar kurulamadı (Kod: $kod)." $false
                }
            } else {
                Write-Result "İşlem iptal edildi." $false
            }
        } else {
            Write-Result "İşlem iptal edildi." $false
        }
    } else {
        Write-Result "Geçersiz seçim." $false
    }
    Write-Host ""
    Read-Host "  Devam etmek için Enter'a basın"
}

function App-Uninstall {
    Show-Header "UYGULAMA KALDIR"
    Show-Line "  Yüklü tüm uygulamalar listeleniyor..." "Yellow"
    Show-Bottom
    Write-Host ""
    if (-not $WingetVar) {
        Write-Result "Winget bulunamadı." $false
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
        Write-Result "İşlem iptal edildi." $false
        Write-Host ""; Read-Host "  Devam etmek için Enter'a basın"; return
    }

    $onay = Read-Host "  '$hedef' kaldırılsın mı? (E/H)"
    if ($onay -ne "E" -and $onay -ne "e") {
        Write-Result "İşlem iptal edildi." $false
        Write-Host ""; Read-Host "  Devam etmek için Enter'a basın"; return
    }

    try {
        # --- KALDIRMA ÖNCESİ: uygulama gerçekten kurulu mu? ---
        $oncesi = (winget list --id $hedef 2>$null | Out-String)
        $varOncesiId = $oncesi -match [regex]::Escape($hedef)
        if (-not $varOncesiId) {
            $oncesiAd = (winget list --name $hedef 2>$null | Out-String)
            $varOncesiId = $oncesiAd -match [regex]::Escape($hedef)
        }

        # --- KALDIRMA: önce ID, başarısızsa Ad ile dene ---
        winget uninstall --id $hedef --silent --accept-source-agreements
        $kod = $LASTEXITCODE
        if ($kod -ne 0) {
            Write-Host "  ID ile bulunamadı, Ad ile deneniyor..." -ForegroundColor DarkGray
            winget uninstall --name $hedef --silent --accept-source-agreements
            $kod = $LASTEXITCODE
        }

        # --- KALDIRMA SONRASI DOĞRULAMA: gerçekten gitti mi? ---
        Start-Sleep -Seconds 1
        $sonrasi = (winget list --id $hedef 2>$null | Out-String)
        $halaVar = $sonrasi -match [regex]::Escape($hedef)
        if (-not $halaVar) {
            $sonrasiAd = (winget list --name $hedef 2>$null | Out-String)
            $halaVar = $sonrasiAd -match [regex]::Escape($hedef)
        }

        # --- SONUCU GERÇEK DURUMA GÖRE BİLDİR ---
        if (-not $varOncesiId) {
            Write-Result "'$hedef' zaten yüklü değildi (kaldırılacak bir şey yok)." $false
        } elseif (-not $halaVar) {
            Write-Result "'$hedef' başarıyla kaldırıldı ve doğrulandı." $true
        } else {
            Write-Result "'$hedef' hâlâ yüklü görünüyor (Kod: $kod). Kaldırma tamamlanamadı." $false
        }
    } catch {
        Write-Result "Kaldırma başarısız: $($_.Exception.Message)" $false
    }
    Write-Host ""
    Read-Host "  Devam etmek için Enter'a basın"
}

function Show-Help {
    Show-Header "YARDIM / HAKKINDA"
    Show-Line "  Bilgisayar Aracı" $Tema.Vurgu
    Show-Line "  Hazırlayan : Mehmet IŞIK" $Tema.Metin
    Show-Line "  Güncelleme : 29.06.2026" $Tema.Metin
    Show-Bos
    Show-Line "  Bu araç; uygulama kurulumu, sistem bilgisi," $Tema.Metin
    Show-Line "  bakım/temizlik ve sürücü yönetimi sağlar." $Tema.Metin
    Show-Bos
    Show-Line "  • Numara yazıp Enter ile işlemi seçin." $Tema.Soluk
    Show-Line "  • 0 yazıp Enter ile programdan çıkın." $Tema.Soluk
    Show-Bos
    # >>> REVİZE: winget durumu ve yardım yönlendirmesi
    if ($WingetVar) {
        Show-Line "  • Winget (paket yöneticisi): YÜKLÜ ✓" $Tema.Basari
    } else {
        Show-Line "  • Winget (paket yöneticisi): YÜKLÜ DEĞİL ✗" $Tema.Hata
        Show-Line "    Kurulum için aşağıdan 'E' seçebilirsiniz." $Tema.Soluk
    }
    Show-Bottom
    Write-Host ""

    # >>> REVİZE: winget kurulum yardımını açma seçeneği
    $wh = Read-Host "  Winget kurulum yardımını görüntülemek ister misiniz? (E/H)"
    if ($wh -eq "E" -or $wh -eq "e") {
        Show-WingetHelp
        # Kullanıcı yardımdan sonra winget kurduysa durumu güncelle
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
        elseif ($sec -eq "H" -or $sec -eq "h") {
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
# Tüm işlemler tek listede — alt menü yok. Numara yazıp Enter'a basın.
# Her satır: numara, başlık (grup), ve çalıştıracağı işlev.
$Menu = @(
    # ===== SOL SÜTUN (1–13) =====
    @{ No = 1;  Grup = "UYGULAMA";  Ad = "Uygulama Kurulumu (liste)";          Eylem = { Invoke-AppMenu } }
    @{ No = 2;  Grup = "UYGULAMA";  Ad = "Tüm Uygulamaları Güncelle";          Eylem = { Update-AllApps } }
    @{ No = 3;  Grup = "UYGULAMA";  Ad = "Uygulama Listesi Dışa/İçe Aktar";    Eylem = { App-ExportImport } }
    @{ No = 4;  Grup = "UYGULAMA";  Ad = "Uygulama Kaldır";                    Eylem = { App-Uninstall } }

    @{ No = 5;  Grup = "TEMİZLİK";  Ad = "Geçici Dosyaları Temizle";           Eylem = { Clean-Temp } }
    @{ No = 6;  Grup = "TEMİZLİK";  Ad = "Windows Loglarını Temizle";          Eylem = { Clean-Logs } }
    @{ No = 7;  Grup = "TEMİZLİK";  Ad = "Windows Update Önbelleği";           Eylem = { Clean-WinUpdate } }
    @{ No = 8;  Grup = "TEMİZLİK";  Ad = "Geri Dönüşüm Kutusunu Boşalt";       Eylem = { Clean-RecycleBin } }
    @{ No = 9;  Grup = "TEMİZLİK";  Ad = "Disk Temizleme (cleanmgr)";          Eylem = { Clean-Disk } }
    @{ No = 10; Grup = "TEMİZLİK";  Ad = "Ekran Kartı Sürücü Artıkları";       Eylem = { Clean-GpuLeftovers } }
    @{ No = 11; Grup = "TEMİZLİK";  Ad = "Sistem Dosyalarını Onar (SFC)";      Eylem = { Repair-SystemFiles } }

    @{ No = 12; Grup = "SÜRÜCÜ";    Ad = "Sürücü Yedekle";                     Eylem = { Backup-Drivers } }
    @{ No = 13; Grup = "SÜRÜCÜ";    Ad = "Sürücü Geri Yükle";                  Eylem = { Restore-Drivers } }

    # ===== SAĞ SÜTUN (14–24) =====
    @{ No = 14; Grup = "BAKIM";     Ad = "Windows Güncellemelerini Tara";      Eylem = { Start-WindowsUpdate } }
    @{ No = 15; Grup = "BAKIM";     Ad = "Ağ Ayarlarını Sıfırla";              Eylem = { Reset-Network } }
    @{ No = 16; Grup = "BAKIM";     Ad = "Geri Yükleme Noktası Oluştur";       Eylem = { New-RestorePoint } }
    @{ No = 17; Grup = "BAKIM";     Ad = "Yazıcı Kuyruğunu Temizle";           Eylem = { Clear-PrintQueue } }

    @{ No = 18; Grup = "BİLGİ";     Ad = "Sistem Bilgileri";                   Eylem = { Show-SystemInfo } }
    @{ No = 19; Grup = "BİLGİ";     Ad = "Disk Özeti";                         Eylem = { Show-DiskSummary } }
    @{ No = 20; Grup = "BİLGİ";     Ad = "Disk Sağlığı (SMART)";               Eylem = { Show-DiskHealth } }
    @{ No = 21; Grup = "BİLGİ";     Ad = "Başlangıç Programları";              Eylem = { Show-Startup } }
    @{ No = 22; Grup = "BİLGİ";     Ad = "Sistem Sağlık Özeti";                Eylem = { Show-HealthSummary } }

    @{ No = 23; Grup = "DİĞER";     Ad = "Yönetim Klasörleri Oluştur";         Eylem = { New-AdminFolders } }
    @{ No = 24; Grup = "DİĞER";     Ad = "Yardım / Hakkında";                  Eylem = { Show-Help } }
)

# ===================== YARDIMCI: MENÜ KOLONU OLUŞTUR =====================
# >>> REVİZE: Get-Kolon, Show-MainMenu'nün DIŞINA taşındı (her çizimde
#     yeniden tanımlanmasını önler). $ikon ve $Menu parametre olarak alınır.
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
    $baslik = "▙▖ B İ L G İ S A Y A R   A R A C I ▟▖"
    $bPad = [math]::Max(1, [math]::Floor(($BoxWidth - $baslik.Length) / 2))
    Write-Host "║" -ForegroundColor $Tema.Cerceve -NoNewline
    Write-Host ((" " * $bPad) + $baslik + (" " * ($BoxWidth - $baslik.Length - $bPad))) -ForegroundColor $Tema.Vurgu -NoNewline
    Write-Host "║" -ForegroundColor $Tema.Cerceve
    $slogan = "Kur • Güncelle • Temizle • Yedekle • Onar"
    $sPad = [math]::Max(1, [math]::Floor(($BoxWidth - $slogan.Length) / 2))
    Write-Host "║" -ForegroundColor $Tema.Cerceve -NoNewline
    Write-Host ((" " * $sPad) + $slogan + (" " * ($BoxWidth - $slogan.Length - $sPad))) -ForegroundColor $Tema.Soluk -NoNewline
    Write-Host "║" -ForegroundColor $Tema.Cerceve

    # ===== CANLI MİNİ SİSTEM DURUMU =====
    $durum = " Sistem durumu okunuyor..."
    try {
        $os = Get-CimInstance Win32_OperatingSystem -ErrorAction SilentlyContinue
        $cDisk = Get-CimInstance Win32_LogicalDisk -Filter "DeviceID='C:'" -ErrorAction SilentlyContinue
        $cTop = [math]::Round($cDisk.Size / 1GB, 0)
        $cBos = [math]::Round($cDisk.FreeSpace / 1GB, 0)
        $cYuzde = if ($cTop -gt 0) { [math]::Round((($cTop - $cBos) / $cTop) * 100) } else { 0 }
        $ramBos = [math]::Round($os.FreePhysicalMemory / 1024 / 1024, 1)
        $durum = " 💽 C: %$cYuzde dolu ($cBos GB boş)   🧠 Boş RAM: $ramBos GB"
    } catch {}
    Write-Host ("╟" + ("─" * $BoxWidth) + "╢") -ForegroundColor $Tema.Cerceve
    $dPad = [math]::Max(1, $BoxWidth - $durum.Length)
    Write-Host "║" -ForegroundColor $Tema.Cerceve -NoNewline
    Write-Host ($durum + (" " * $dPad)).Substring(0, $BoxWidth) -ForegroundColor $Tema.Basari -NoNewline
    Write-Host "║" -ForegroundColor $Tema.Cerceve
    Write-Host ("╟" + ("─" * $BoxWidth) + "╢") -ForegroundColor $Tema.Cerceve

    # ===== İKONLU GRUP DAĞILIMI (dengeli 12/12) =====
    $ikon = @{
        "UYGULAMA" = "📦"; "BİLGİ" = "ℹ️ "; "TEMİZLİK" = "🧹"
        "BAKIM"    = "🔧"; "SÜRÜCÜ" = "💾"; "DİĞER"    = "⚙️ "
    }
    $solGruplar = @("UYGULAMA", "TEMİZLİK", "SÜRÜCÜ")
    $sagGruplar = @("BAKIM", "BİLGİ", "DİĞER")

    # >>> REVİZE: Get-Kolon artık dışarıda; $ikon ve $Menu parametre geçiliyor
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

    # >>> PRO DOKUNUŞ: Windows Terminal yüklü DEĞİLSE ipucu satırı göster
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
