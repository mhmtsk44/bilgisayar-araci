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

> Bu yöntem script'i **belleğe** indirip çalıştırır. `ExecutionPolicy` ayarına **takılmaz**, dosya kaydetmez. En pratik yol budur.

### Yöntem 2 — Yerel Dosya
1. `Bilgisayar_Araci.ps1` dosyasını indirin (örn. Masaüstü).
2. Dosyaya **sağ tık → "PowerShell ile çalıştır"**.
3. Script kendini otomatik olarak **yönetici** yetkisiyle ve **Windows Terminal**'de yeniden başlatır.

---

## 🔐 ExecutionPolicy Ayarı (Yerel dosya için tek seferlik)

Windows, güvenlik gereği script'lerin çalışmasını varsayılan olarak kısıtlar. **Yerel `.ps1` dosyasını** çalıştırmak istediğinizde, o bilgisayarda **bir kez** şu komutu çalıştırmanız yeterlidir:

```powershell
Set-ExecutionPolicy RemoteSigned -Scope CurrentUser
```

| Özellik | Açıklama |
|--------|----------|
| ✅ **Yönetici gerekmez** | `-Scope CurrentUser` kullandığı için normal kullanıcı çalıştırabilir. |
| ✅ **Kalıcıdır** | Bir kez ayarlanır, o kullanıcı için sürekli geçerlidir. |
| ✅ **Güvenlidir** | `RemoteSigned`: yerel script'ler serbest, internetten inen imzasız script'ler engellenir. |

**Notlar:**
- `irm | iex` (Yöntem 1) kullanıyorsanız bu adıma **gerek yoktur** — bellekte çalıştığı için politikaya takılmaz.
- Dosyayı internetten indirdiyseniz ve "engellendi" uyarısı alırsanız, tek seferlik:
  ```powershell
  Unblock-File .\Bilgisayar_Araci.ps1
  ```
=- Alternatif (kalıcı ayar yapmadan tek çalıştırma):
  ```powershell
  powershell -ExecutionPolicy Bypass -File "Bilgisayar_Araci.ps1"
  ```

=---

## ✨ Özellikler### 📦 Uygulama Yönetimi
- Hazır listeden toplu uygulama kurulumu (winget tabanlı)
- Tüm uygulamaları tek tıkla güncelleme (hibrit: winget + mağaza)
- Uygulama arama; kurma ve kaldırma
- Uygulama listesini dışa/içe aktarma (yedekleme)### 🧹 Temizlik
- Geçici dosyalar; Windows logları; Update önbelleği
- Geri dönüşüm kutusu; disk temizleme (cleanmgr)
- Ekran kartı sürücü artıklarının temizliği
- Bozuk sistem dosyalarını onarma (SFC/DISM)### 💾 Sürücü İşlemleri
- Sistemdeki tüm sürücüleri **yedekleme** (export)
- Yedekten sürücüleri **geri yükleme**

### 🛠️ Bakım
- Disk kontrol ve onarım (chkdsk — seçmeli)
- **Güvenli / korumalı USB** oluşturma
- Windows güncellemelerini tarama; ağ ayarlarını sıfırlama
- Sistem geri yükleme noktası; yazıcı kuyruğu temizliği### 📊 Bilgi & Tanılama
- Sistem bilgileri; disk özeti; disk sağlığı (SMART)
- Başlangıç programları; sistem sağlık özeti### ⚙️ Diğer
- Yönetim klasörleri oluşturma; yardım/hakkında

---

## 📋 Gereksinimler

| Gereksinim | Açıklama |
|-----------|----------|
| **İşletim Sistemi** | Windows 10 (1809+) / Windows 11 |
| **PowerShell** | 5,1+ (Windows'ta yerleşik) |
| **Yetki** | Yönetici (script otomatik yükseltir) |
| **Winget** | Yoksa script otomatik kurmayı dener (LTSC uyumlu) |
| **İnternet** | Uygulama kurulumu/güncelleme için gerekli |

---

## 📥 Kurulum Yöntemleri

| Yöntem | Komut / Adım | ExecutionPolicy | Not |
|--------|--------------|-----------------|-----|
| **Tek satır** | `irm https://tinyurl.com/27kxfp7y \| iex` | Gerekmez | En pratik, kaydetmez |
| **Yerel dosya** | Sağ tık → "PowerShell ile çalıştır" | `RemoteSigned` (1 kez) | Offline çalışır |
| **Manuel komut** | `powershell -ExecutionPolicy Bypass -File "Bilgisayar_Araci.ps1"` | Bypass (tek sefer) | Kalıcı ayar yapmaz |

> Script **kendini yönetici** yapar ve **Windows Terminal**'de açar. Sonsuz döngü koruması yerleşiktir.

---

## 🧩 Kurulan Uygulama Listesi

|# | Uygulama |# | Uygulama |
|---|----------|---|----------|
| 1 | Google Chrome | 9 | Visual Studio Code |
| 2 | WinRAR | 10 | UniGetUI |
| 3 | ACS Unified PC/SC Driver | 11 | PowerToys |
| 4 | Adobe Reader | 12 | PowerShell 7 |
| 5 | Internet Download Manager | 13 | Oracle Java Runtime |
| 6 | Mozilla Firefox | 14 | 7-Zip |
| 7 | VLC Media Player | 15 | Windows Terminal |
| 8 | Notepad++ | 16 | Microsoft.[NET] Runtime |

> Tam liste script içindeki `$Uygulamalar` dizisinden yönetilir; kolayca ekleme/çıkarma yapabilirsiniz.

---

## 🗂️ Menü Düzeni (27 İşlem)

|# | İşlem |# | İşlem |
|---|-------|---|-------|
| **📦 UYGULAMA** | | **🛠️ BAKIM** | |
| 1 | Uygulama Kurulumu (liste) | 15 | Disk Kontrol ve Onarım (chkdsk) |
| 2 | Tüm Uygulamaları Güncelle | 16 | Güvenli USB Oluştur (Korumalı) |
| 3 | Uygulama Ara ve Kur | 17 | Windows Güncellemelerini Tara |
| 4 | Uygulama Listesi Dışa/İçe Aktar | 18 | Ağ Ayarlarını Sıfırla |
| 5 | Uygulama Kaldır | 19 | Geri Yükleme Noktası Oluştur |
| **🧹 TEMİZLİK** | | 20 | Yazıcı Kuyruğunu Temizle |
| 6 | Geçici Dosyaları Temizle | **📊 BİLGİ** | |
| 7 | Windows Loglarını Temizle | 21 | Sistem Bilgileri |
| 8 | Windows Update Önbelleği | 22 | Disk Özeti |
| 9 | Geri Dönüşüm Kutusunu Boşalt | 23 | Disk Sağlığı (SMART) |
| 10 | Disk Temizleme (cleanmgr) | 24 | Başlangıç Programları |
| 11 | Ekran Kartı Sürücü Artıkları | 25 | Sistem Sağlık Özeti |
| 12 | Sistem Dosyalarını Onar | **⚙️ DİĞER** | |
| **💾 SÜRÜCÜ** | | 26 | Yönetim Klasörleri Oluştur |
| 13 | Sürücü Yedekle | 27 | Yardım / Hakkında |
| 14 | Sürücü Geri Yükle | **0** | **Çıkış** |

---

## ⚠️ Uyarı

- Bu araç **sistem düzeyinde** değişiklikler yapar (disk onarımı; ağ sıfırlama; sürücü işlemleri).
- Kritik işlemlerden (chkdsk; sürücü geri yükleme; USB oluşturma) önce **veri yedeği** alın.
- Yalnızca **kendi bilgisayarınızda** veya yetkiniz olan cihazlarda kullanın.
- USB oluşturma işlemi hedef sürücüdeki **tüm verileri siler**.---

## 👤 Hazırlayan

**Mehmet IŞIK**
Güncelleme: 04.07.2026

---

## 📄 Lisans

Kişisel kullanım içindir. Serbestçe dağıtılabilir; sorumluluk kullanıcıya aittir.
````
