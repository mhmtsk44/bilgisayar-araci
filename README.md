# 🖥️ Bilgisayar Aracı

> **Kur • Güncelle • Temizle • Yedekle • Onar**
> Windows için hepsi bir arada bakım ve kurulum aracı.

**Hazırlayan:** Mehmet IŞIK
**Sürüm:** v2026 (Güncelleme: 03.07.2026)

---

## 🚀 Hızlı Başlangıç

PowerShell'i açın ve aşağıdaki komutu yapıştırın:

    irm https://tinyurl.com/27kxfp7y | iex

Program otomatik olarak yönetici izni ister, Windows Terminal'de açılır (yoksa kurar) ve menüyü başlatır.

---

## ✨ Özellikler

### 📦 Uygulama
- Toplu uygulama kurulumu (16 hazır uygulama listesiyle)
- Tüm uygulamaları güncelleme (`winget upgrade --all`)
- Uygulama arama ve kurma (`winget search`)
- Uygulama listesini dışa/içe aktarma (JSON)
- Uygulama kaldırma (ID veya ad ile)

### 🧹 Temizlik
- Geçici dosyaları temizleme
- Windows olay günlüklerini temizleme (canlı yüzdeli çubuk)
- Windows Update önbelleğini temizleme
- Geri dönüşüm kutusunu boşaltma
- Disk Temizleme (cleanmgr)
- Ekran kartı sürücü artıklarını temizleme (AMD / NVIDIA / Intel)
- Sistem dosyalarını onarma (DISM + SFC, canlı yüzdeli çubuk)

### 💾 Sürücü
- Sürücü yedekleme (canlı listeleme)
- Sürücü geri yükleme

### 🔧 Bakım
- Disk kontrol ve onarım (chkdsk — hızlı / derin mod)
- Güvenli USB oluşturma / biçimlendirme (korumalı)
- Windows güncellemelerini tarama (PSWindowsUpdate)
- Ağ ayarlarını sıfırlama (DNS, Winsock, IP)
- Geri yükleme noktası oluşturma
- Yazıcı kuyruğunu temizleme

### ℹ️ Bilgi
- Sistem bilgileri
- Disk özeti
- Disk sağlığı (SMART)
- Başlangıç programları
- Sistem sağlık özeti

### ⚙️ Diğer
- Yönetim (GodMode) klasörleri oluşturma
- Yardım / Hakkında

---

## 📋 Gereksinimler
- Windows 10 (1809+) veya Windows 11
- PowerShell 5.1 veya üzeri
- Yönetici hakları (program otomatik ister)
- İnternet bağlantısı (uygulama kurulumu için)
- Winget (yoksa program açılışta otomatik kurmayı dener — LTSC uyumlu)

---

## ⚙️ Kurulum Yöntemleri

| Yöntem | Komut |
|--------|-------|
| **PowerShell** | `irm https://tinyurl.com/27kxfp7y \| iex` |
| **CMD** | `powershell -ExecutionPolicy Bypass -Command "irm 'https://tinyurl.com/27kxfp7y' \| iex"` |
| **Yerel dosya** | `powershell -ExecutionPolicy RemoteSigned -File "Bilgisayar_Araci.ps1"` |

> **Not:** Dosyayı yerel olarak kaydediyorsanız **"UTF-8 with BOM"** olarak kaydedin (Türkçe karakterler + çerçeve simgeleri için).

---

## 📦 Hazır Uygulama Listesi

Kurulum menüsünde (Menü 1) tek tuşla kurulabilen uygulamalar:

Google Chrome, WinRAR, ACS Unified PC/SC Driver, Adobe Reader, Internet Download Manager, Mozilla Firefox, VLC Media Player, Notepad++, Visual Studio Code, UniGetUI, PowerToys, PowerShell 7, Oracle Java Runtime, Microsoft PC Manager, Windows Terminal, Alpemix (Uzak Bağlantı).

> **Alpemix** winget'siz de çalışır (doğrudan imza kontrollü indirme). **Microsoft PC Manager** Microsoft Store kaynağından kurulur.

---

## 📑 Menü Düzeni (27 İşlem)

Program tek düz (flat) menü kullanır — numara yazıp Enter'a basın:

| No | İşlem | No | İşlem |
|----|-------|----|-------|
| 1  | Uygulama Kurulumu (liste)      | 15 | Disk Kontrol ve Onarım (chkdsk) |
| 2  | Tüm Uygulamaları Güncelle      | 16 | Güvenli USB Oluştur (Korumalı) |
| 3  | Uygulama Ara ve Kur (winget)   | 17 | Windows Güncellemelerini Tara |
| 4  | Uygulama Listesi Dışa/İçe Aktar| 18 | Ağ Ayarlarını Sıfırla |
| 5  | Uygulama Kaldır                | 19 | Geri Yükleme Noktası Oluştur |
| 6  | Geçici Dosyaları Temizle       | 20 | Yazıcı Kuyruğunu Temizle |
| 7  | Windows Loglarını Temizle      | 21 | Sistem Bilgileri |
| 8  | Windows Update Önbelleği       | 22 | Disk Özeti |
| 9  | Geri Dönüşüm Kutusunu Boşalt   | 23 | Disk Sağlığı (SMART) |
| 10 | Disk Temizleme (cleanmgr)      | 24 | Başlangıç Programları |
| 11 | Ekran Kartı Sürücü Artıkları   | 25 | Sistem Sağlık Özeti |
| 12 | Sistem Dosyalarını Onar        | 26 | Yönetim Klasörleri Oluştur |
| 13 | Sürücü Yedekle                 | 27 | Yardım / Hakkında |
| 14 | Sürücü Geri Yükle              | 0  | Çıkış |

---

## ⚠️ Uyarı

Bu araç sistem dosyaları, sürücüler ve disklerle çalışır. Önemli işlemlerden önce **geri yükleme noktası oluşturmanız** önerilir (Menü 19). USB biçimlendirme (Menü 16) ve chkdsk (Menü 15) gibi işlemler veri kaybına yol açabilir — onay ekranlarını dikkatle okuyun.

---

## 👤 Hazırlayan

**Mehmet IŞIK**

Bilgisayar Aracı • v2026

---

## 📄 Lisans

Bu proje kişisel kullanım için hazırlanmıştır.
