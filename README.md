# 🖥️ Bilgisayar Aracı

> **Windows için hepsi-bir-arada sistem bakım aracı**
> Uygulama kurulumu • Güncelleme • Sürücü yedekleme • Temizlik • Bakım — tek PowerShell script'inde.

**Hazırlayan:** Mehmet IŞIK · **Güncelleme:** 04.07.2026

---

## 🚀 Hızlı Başlangıç

### Yöntem 1 — Tek Satır (Önerilen, kurulum gerektirmez)

Yönetici PowerShell açıp şunu yapıştırın:

```powershell
irm https://tinyurl.com/27kxfp7y | iex
```

> Bu yöntem script'i **belleğe** indirip çalıştırır. `ExecutionPolicy` ayarına **takılmaz**, dosya kaydetmez, **BOM/encoding sorunu yaşanmaz** (PowerShell script'i doğrudan UTF-8 olarak indirip yorumlar). En pratik yol budur.

### Yöntem 2 — Yerel Dosya (örn. Masaüstü)

1. `Bilgisayar_Araci.ps1` dosyasını indirin (örn. Masaüstüne kaydedin).
2. Dosyaya **sağ tık → "PowerShell ile çalıştır"**.
3. Script kendini otomatik olarak **yönetici** yetkisiyle ve **Windows Terminal**'de (varsa) yeniden başlatır; sonsuz döngüye girmemesi için ortam değişkeni bayrağı kullanır.

> ⚠️ **Önemli:** Dosyayı masaüstünde/yerelde çalıştıracaksanız, Türkçe karakterlerin (ç, ğ, ı, ö, ş, ü) ve çerçeve simgelerinin (╔ ║ ✦ vb.) doğru görünmesi için dosyanın **"UTF-8 with BOM"** olarak kaydedilmiş olması gerekir. Aşağıdaki [UTF-8 (BOM) Dönüştürme](#-utf-8-bom-dönüştürme-masaüstünde-doğru-çalışması-için) bölümüne bakın.

---

## 🔡 UTF-8 (BOM) Dönüştürme — Masaüstünde Doğru Çalışması İçin

Windows PowerShell 5.1, BOM içermeyen `.ps1` dosyalarını UTF-8 yerine sistem kod sayfasına göre okur; bu yüzden Türkçe karakterler ve çerçeve simgeleri (╔ ║ ✦ vb.) yerelde bozuk görünebilir. `irm | iex` (Yöntem 1) ile çalıştırırken bu sorun yaşanmaz; yalnızca yerel dosyayı çalıştırırken geçerlidir. Çözüm, dosyanın bulunduğu klasörde şu komutu çalıştırmak:

```powershell
$p = "$env:USERPROFILE\Desktop\Bilgisayar_Araci.ps1"; [IO.File]::WriteAllText($p, (Get-Content $p -Raw -Encoding UTF8), [Text.UTF8Encoding]::new($true))
```

---

## 🔐 ExecutionPolicy Ayarı (Yerel dosya için tek seferlik)

Windows, güvenlik gereği script'lerin çalışmasını varsayılan olarak kısıtlar. **Yerel `.ps1` dosyasını** çalıştırmak istediğinizde, o bilgisayarda **bir kez** şu komutu çalıştırmanız yeterlidir:

```powershell
Set-ExecutionPolicy RemoteSigned -Scope CurrentUser
```

| Özellik | Açıklama |
|---|---|
| ✅ **Yönetici gerekmez** | `-Scope CurrentUser` kullandığı için normal kullanıcı çalıştırabilir. |
| ✅ **Kalıcıdır** | Bir kez ayarlanır, o kullanıcı için sürekli geçerlidir. |
| ✅ **Güvenlidir** | `RemoteSigned`: yerel script'ler serbest, internetten inen imzasız script'ler engellenir. |

**Notlar:**

- `irm | iex` (Yöntem 1) kullanıyorsanız bu adıma **gerek yoktur** — bellekte çalıştığı için politikaya takılmaz.
- Dosyayı internetten indirdiyseniz ve "engellendi" uyarısı alırsanız, tek seferlik:
  ```powershell
  Unblock-File .\Bilgisayar_Araci.ps1
  ```
- Alternatif (kalıcı ayar yapmadan tek çalıştırma):
  ```powershell
  powershell -ExecutionPolicy Bypass -File "Bilgisayar_Araci.ps1"
  ```

---

## ⚙️ Script Nasıl Çalışır (Başlatma Akışı)

Script çalıştırıldığında sırasıyla şu adımları izler:

1. **Yönetici kontrolü:** Yönetici değilseniz, script kendisini `-Verb RunAs` ile **yönetici izniyle** yeniden başlatır (UAC penceresi çıkar).
2. **Winget garanti altına alınır:** Sistemde winget yoksa, LTSC/LTSB dahil, script otomatik kurmayı dener (öncelik: resmi kurulum, yedek: manuel MSIX kurulumu).
3. **Windows Terminal'e geçiş:** `wt.exe` kurulu ve script şu an bir Windows Terminal oturumunda değilse, script kendini **Windows Terminal içinde** yeniden açar (daha iyi Unicode/renk desteği için). Sonsuz döngüye girmemesi için `BILGISAYAR_ARACI_WT` ortam değişkeni kullanılır.
4. **Ana menü** görüntülenir ve kullanıcı seçimini bekler.

> Yerel dosyadan çalıştırıldığında bu adımlar **aynı dosyayı** yeniden başlatır; `irm | iex` ile çalıştırıldığında ise script'i GitHub'dan tekrar indirip çalıştırır (`$ScriptUrl` değişkeni).

---

## ✨ Özellikler

### 📦 Uygulama Yönetimi
- Hazır listeden toplu uygulama kurulumu (winget tabanlı)
- Tüm uygulamaları tek tıkla güncelleme (hibrit: winget + mağaza)
- Uygulama arama; kurma ve kaldırma
- Uygulama listesini dışa/içe aktarma (yedekleme)

### 🧹 Temizlik
- Geçici dosyalar; Windows logları; Update önbelleği
- Geri dönüşüm kutusu; disk temizleme (cleanmgr)
- Ekran kartı sürücü artıklarının temizliği
- Bozuk sistem dosyalarını onarma (SFC/DISM)

### 💾 Sürücü İşlemleri
- Sistemdeki tüm sürücüleri **yedekleme** (export)
- Yedekten sürücüleri **geri yükleme**

### 🛠️ Bakım
- Disk kontrol ve onarım (chkdsk — seçmeli)
- **Güvenli / korumalı USB** oluşturma
- Windows güncellemelerini tarama; ağ ayarlarını sıfırlama
- Sistem geri yükleme noktası; yazıcı kuyruğu temizliği

### 📊 Bilgi & Tanılama
- Sistem bilgileri; disk özeti; disk sağlığı (SMART)
- Başlangıç programları; sistem sağlık özeti

### ⚙️ Diğer
- Yönetim klasörleri oluşturma; yardım/hakkında

---

## 📋 Gereksinimler

| Gereksinim | Açıklama |
|---|---|
| **İşletim Sistemi** | Windows 10 (1809+) / Windows 11 |
| **PowerShell** | 5.1+ (Windows'ta yerleşik) |
| **Yetki** | Yönetici (script otomatik yükseltir) |
| **Winget** | Yoksa script otomatik kurmayı dener (LTSC uyumlu); yine de kurulamazsa araç winget gerektirmeyen özelliklerle (temizlik, bilgi, bakım vb.) çalışmaya devam eder |
| **İnternet** | Uygulama kurulumu/güncelleme için gerekli |
| **Dosya Kodlaması** | Yerelde çalıştırılacaksa **UTF-8 (BOM)** — bkz. yukarıdaki "UTF-8 (BOM) Dönüştürme" bölümü (tek satır komutla düzeltilir) |

---

## 📥 Kurulum Yöntemleri

| Yöntem | Komut / Adım | ExecutionPolicy | Not |
|---|---|---|---|
| **Tek satır** | `irm https://tinyurl.com/27kxfp7y \| iex` | Gerekmez | En pratik, kaydetmez, encoding sorunu yok |
| **Yerel dosya** | Sağ tık → "PowerShell ile çalıştır" | `RemoteSigned` (1 kez) | Offline çalışır, **UTF-8 BOM gerektirir** |
| **Manuel komut** | `powershell -ExecutionPolicy Bypass -File "Bilgisayar_Araci.ps1"` | Bypass (tek sefer) | Kalıcı ayar yapmaz |

> Script **kendini yönetici** yapar ve **Windows Terminal**'de açar. Sonsuz döngü koruması yerleşiktir.

---

## 🧩 Kurulan Uygulama Listesi

| # | Uygulama | # | Uygulama |
|---|---|---|---|
| 1 | Google Chrome | 9 | Visual Studio Code |
| 2 | WinRAR | 10 | UniGetUI |
| 3 | ACS Unified PC/SC Driver | 11 | PowerToys |
| 4 | Adobe Reader | 12 | PowerShell 7 |
| 5 | Internet Download Manager | 13 | Oracle Java Runtime |
| 6 | Mozilla Firefox | 14 | Microsoft PC Manager *(Store)* |
| 7 | VLC Media Player | 15 | Windows Terminal |
| 8 | Notepad++ | 16 | Alpemix *(Uzak Bağlantı)* |

> Tam liste script içindeki uygulama dizisinden yönetilir; kolayca ekleme/çıkarma yapabilirsiniz.
>
> **Notlar:**
> - **Microsoft PC Manager** winget yerine `msstore` kaynağından kurulur.
> - **Alpemix**, winget'te bulunmadığı için doğrudan `alpemix.com` üzerinden masaüstüne indirilir; kurulum öncesi dosyanın **dijital imzası** otomatik olarak doğrulanır ve imza geçersizse kullanıcı uyarılır.

---

## 🗂️ Menü Düzeni (27 İşlem)

### 📦 Uygulama Yönetimi

| # | İşlem |
|:-:|---|
| 01 | Uygulama Kurulumu (liste) |
| 02 | Tüm Uygulamaları Güncelle |
| 03 | Uygulama Ara ve Kur |
| 04 | Uygulama Listesi Dışa/İçe Aktar |
| 05 | Uygulama Kaldır |

### 🧹 Temizlik

| # | İşlem |
|:-:|---|
| 06 | Geçici Dosyaları Temizle |
| 07 | Windows Loglarını Temizle |
| 08 | Windows Update Önbelleği |
| 09 | Geri Dönüşüm Kutusunu Boşalt |
| 10 | Disk Temizleme (cleanmgr) |
| 11 | Ekran Kartı Sürücü Artıkları |
| 12 | Sistem Dosyalarını Onar (SFC/DISM) |

### 💾 Sürücü İşlemleri

| # | İşlem |
|:-:|---|
| 13 | Sürücü Yedekle |
| 14 | Sürücü Geri Yükle |

### 🛠️ Bakım

| # | İşlem |
|:-:|---|
| 15 | Disk Kontrol ve Onarım (chkdsk) |
| 16 | Güvenli USB Oluştur (Korumalı) |
| 17 | Windows Güncellemelerini Tara |
| 18 | Ağ Ayarlarını Sıfırla |
| 19 | Geri Yükleme Noktası Oluştur |
| 20 | Yazıcı Kuyruğunu Temizle |

### 📊 Bilgi & Tanılama

| # | İşlem |
|:-:|---|
| 21 | Sistem Bilgileri |
| 22 | Disk Özeti |
| 23 | Disk Sağlığı (SMART) |
| 24 | Başlangıç Programları |
| 25 | Sistem Sağlık Özeti |

### ⚙️ Diğer

| # | İşlem |
|:-:|---|
| 26 | Yönetim Klasörleri Oluştur |
| 27 | Yardım / Hakkında |
| 00 | Çıkış |

---

## ⚠️ Uyarı

- Bu araç **sistem düzeyinde** değişiklikler yapar (disk onarımı, ağ sıfırlama, sürücü işlemleri).
- Kritik işlemlerden (chkdsk, sürücü geri yükleme, USB oluşturma) önce **veri yedeği** alın.
- Yalnızca **kendi bilgisayarınızda** veya yetkiniz olan cihazlarda kullanın.
- USB oluşturma işlemi hedef sürücüdeki **tüm verileri siler**.

---

## 👤 Hazırlayan

**Mehmet IŞIK**
Güncelleme: 04.07.2026

---

## 📄 Lisans

Kişisel kullanım içindir. Serbestçe dağıtılabilir; sorumluluk kullanıcıya aittir.
