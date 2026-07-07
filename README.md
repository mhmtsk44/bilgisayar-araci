# 🖥️ Bilgisayar Aracı

> **Windows için hepsi-bir-arada sistem bakım aracı**
> Uygulama kurulumu • Güncelleme • Sürücü yedekleme • Temizlik • Bakım — tek PowerShell script'inde.

**Hazırlayan:** Mehmet IŞIK · **Güncelleme:** 07.07.2026

---

## 🚀 Hızlı Başlangıç

### Yöntem 1 — Tek Satır (Önerilen, kurulum gerektirmez)

Yönetici PowerShell açıp şunu yapıştırın:

```powershell
irm https://tinyurl.com/27kxfp7y | iex
```

> Bu yöntem script'i **belleğe** indirip çalıştırır. `ExecutionPolicy` ayarına **takılmaz**, dosya kaydetmez, **BOM/encoding sorunu yaşanmaz** (PowerShell script'i doğrudan UTF-8 olarak indirip yorumlar). En pratik yol budur.

### Yöntem 2 — Yerel Dosya (örn. Masaüstü)

1. Projeyi **zip olarak indirin** ve Masaüstüne çıkarın (klasör adı: `bilgisayar-araci-main`).
2. Bir PowerShell penceresinde şu komutu çalıştırın (Türkçe karakter/çerçeve simgelerinin bozuk görünmemesi için **gereklidir**.
   ```powershell
   $p = "$env:USERPROFILE\Desktop\bilgisayar-araci-main\Bilgisayar_Araci.ps1"; [IO.File]::WriteAllText($p, (Get-Content $p -Raw -Encoding UTF8), [Text.UTF8Encoding]::new($true))
   ```
3. `Bilgisayar_Araci.ps1` dosyasına **sağ tık → "PowerShell ile çalıştır"**.
4. Script kendini otomatik olarak **yönetici** yetkisiyle ve **Windows Terminal**'de (varsa) yeniden başlatır; sonsuz döngüye girmemesi için ortam değişkeni bayrağı kullanır.

> ⚠️ **2. adımı atlamayın:** Windows PowerShell 5.1, BOM içermeyen `.ps1` dosyalarını UTF-8 yerine sistem kod sayfasına göre okur; bu yüzden Türkçe karakterler ve çerçeve simgeleri (╔ ║ ✦ vb.) bu adım atlanırsa bozuk görünür.

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
- **Uygulamaları güncelle**: önce güncellenebilir uygulamaları listeler, ardından seçtiklerinizi veya hepsini güncellemenizi sağlar (Microsoft.WinGet.Client modülü ile, metin ayrıştırması yapılmaz)
- Uygulama arama; kurma ve kaldırma
- Uygulama listesini dışa/içe aktarma (yedekleme)

### 🧹 Temizlik
- **Standart Disk Temizliği**: Windows'un yerleşik `cleanmgr` aracı
- **Derin Sistem Temizliği** (kategori seçmeli, örn: `1,3,5` veya "Hepsi"):
  - Geçici sistem/kullanıcı dosyaları (Temp, Prefetch)
  - Tarayıcı önbellekleri (Chrome, Edge — şifrelere dokunulmaz)
  - Windows Update indirme önbelleği
  - Ekran kartı kurulum artıkları (AMD/NVIDIA/Intel)
  - Geri dönüşüm kutusu
  - Gereksiz Windows olay günlükleri (loglar)
- Yazıcı kuyruğu temizliği

### 💾 Sürücü İşlemleri
- Sistemdeki tüm sürücüleri **yedekleme** (export)
- Yedekten sürücüleri **geri yükleme**

### 🛠️ Bakım
- **Sistem ve disk onarımı**: SFC, DISM ve chkdsk tek menüde; "Tam Sistem Onarımı" (DISM + SFC birlikte) seçeneği
- **Güvenli / korumalı USB** oluşturma
- **Disk temizle ve dönüştür (GPT/MBR)**: diskpart'ın `clean` + `convert` komutlarının karşılığı; seri numarasıyla disk ayrımı, çift katmanlı sistem diski koruması, işlem sonrası isteğe bağlı bölüm oluşturma
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
| **PowerShell Modülü** | "Uygulamaları Güncelle" için `Microsoft.WinGet.Client` modülü gerekir; ilk kullanımda internetten otomatik kurulur |
| **İnternet** | Uygulama kurulumu/güncelleme için gerekli |

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

## 🗂️ Menü Düzeni

Ana menüde **16 madde** yer alır; bir kısmı doğrudan işlem yapar, bir kısmı ise alt menü açar (aşağıda **↳** ile gösterilmiştir).

### 📦 Uygulama Yönetimi

| # | İşlem |
|:-:|---|
| 01 | Uygulama Kurulumu (liste) |
| 02 | Uygulamaları Güncelle |
| 03 | Uygulama Ara / Kaldır ↳ *1) Ara ve Kur (winget) · 2) Kaldır* |
| 04 | Uygulama Listesi Dışa/İçe Aktar |

### 🛠️ Bakım

| # | İşlem |
|:-:|---|
| 05 | Sistem ve Disk Onarımı ↳ *SFC · DISM · chkdsk · Tam Sistem Onarımı* |
| 06 | Disk Temizle ve Dönüştür (GPT/MBR) |
| 07 | Güvenli USB Oluştur (Korumalı) |
| 08 | Windows Güncellemelerini Tara |
| 09 | Ağ Ayarlarını Sıfırla |
| 10 | Geri Yükleme Noktası Oluştur |

### 🧹 Temizlik

| # | İşlem |
|:-:|---|
| 11 | Sistem Temizliği ↳ *1) Standart Disk Temizliği (cleanmgr) · 2) Derin Sistem Temizliği (kategori seçmeli)* |
| 12 | Yazıcı Kuyruğunu Temizle |

### 💾 Sürücü İşlemleri

| # | İşlem |
|:-:|---|
| 13 | Sürücü Yönetimi ↳ *1) Sürücü Yedekle · 2) Sürücü Geri Yükle* |

### 📊 Bilgi & Tanılama

| # | İşlem |
|:-:|---|
| 14 | Sistem Bilgileri ↳ *1) Sistem Bilgileri · 2) Disk Özeti · 3) Disk Sağlığı (SMART) · 4) Başlangıç Programları · 5) Sistem Sağlık Özeti* |

### ⚙️ Diğer

| # | İşlem |
|:-:|---|
| 15 | Yönetim Klasörleri Oluştur |
| 16 | Yardım / Hakkında |
| 00 | Çıkış |

> Ana menü ekranında işlemler iki sütun halinde grup başlıklarıyla (📦 UYGULAMA, 🔧 BAKIM, 🧹 TEMİZLİK, 💾 SÜRÜCÜ, ℹ️ BİLGİ, ⚙️ DİĞER) listelenir; üstte anlık **C: disk doluluğu** ve **boş RAM** bilgisi gösterilir.

---

## ⚠️ Uyarı

- Bu araç **sistem düzeyinde** değişiklikler yapar (disk onarımı, ağ sıfırlama, sürücü işlemleri).
- Kritik işlemlerden (chkdsk, sürücü geri yükleme, USB oluşturma, **disk temizle/dönüştür**) önce **veri yedeği** alın.
- Yalnızca **kendi bilgisayarınızda** veya yetkiniz olan cihazlarda kullanın.
- USB oluşturma işlemi ve **"Disk Temizle ve Dönüştür"** hedef diskteki **tüm verileri siler**.

---

## 👤 Hazırlayan

**Mehmet IŞIK**
Güncelleme: 07.07.2026

---

## 📄 Lisans

Kişisel kullanım içindir. Serbestçe dağıtılabilir; sorumluluk kullanıcıya aittir.
