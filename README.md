# 🧰 Multitool - TVBox Project Fork | Fork do Projeto TVBox

<div align="center">
  
  ![Linux Penguin](https://img.shields.io/badge/Linux-FCC624?style=for-the-badge&logo=linux&logoColor=black) 
  ![Debian](https://img.shields.io/badge/Debian-D70A53?style=for-the-badge&logo=debian&logoColor=white)
  ![ARM](https://img.shields.io/badge/ARM-0091BD?style=for-the-badge&logo=arm&logoColor=white)
  
  **🐧 A modified version of the Multitool used by the TVBox Project (IFSP Salto) to flash seized TV boxes with clean, open-source Linux distributions like Armbian.**
  
  **🐧 Uma versão modificada do Multitool usada pelo Projeto TVBox (IFSP Salto) para instalar distribuições Linux livres como Armbian em TV boxes apreendidas.**

</div>

---

## 📋 Table of Contents | Índice

- [🚀 About | Sobre](#-about--sobre)
  - [📺 TVBox Project | Projeto TVBox](#-tvbox-project--projeto-tvbox)
  - [🔧 Fork Features | Funcionalidades do Fork](#-fork-features--funcionalidades-do-fork)
- [⚡ Quick Start | Início Rápido](#-quick-start--início-rápido)
- [📦 Installation | Instalação](#-installation--instalação)
- [🎯 Usage | Uso](#-usage--uso)
- [🏗️ Building | Compilação](#️-building--compilação)
- [🤝 Contributing | Contribuindo](#-contributing--contribuindo)
- [📞 Contact | Contato](#-contact--contato)
- [📜 License | Licença](#-license--licença)
- [🙏 Credits | Créditos](#-credits--créditos)

---

## 🚀 About | Sobre

### 📺 TVBox Project | Projeto TVBox

This fork is part of the **TVBox Project**, developed by students and researchers at the **Federal Institute of São Paulo (IFSP) - Salto Campus**. The project focuses on repurposing seized TV boxes from the Federal Revenue Service by installing clean, open-source Linux distributions like Armbian.

Este fork faz parte do **Projeto TVBox**, desenvolvido por estudantes e pesquisadores do **Instituto Federal de São Paulo (IFSP) - Campus Salto**. O projeto foca em reaproveitar TV boxes apreendidas pela Receita Federal instalando distribuições Linux livres como Armbian.

### 🔧 Fork Features | Funcionalidades do Fork

**🆕 New in this fork | Novidades neste fork:**

- **🤖 Automatic Restore**: Auto-restore functionality that starts immediately after boot
- **⏱️ Timed Operation**: 10-second countdown after license dialog (additional 5 seconds if auto-closed)
- **📁 Backup Selection**: Menu-driven backup file selection through the original multitool interface
- **🚀 Mass Processing**: Streamlined workflow for bulk TV box decharacterization
- **🛠️ Fixed Dependencies**: Updated Debian repository URLs for reliable builds

**🤖 Restauração Automática**: Funcionalidade de restore automático que inicia imediatamente após o boot  
**⏱️ Operação Temporizada**: Contagem regressiva de 10 segundos após o diálogo de licença (5 segundos adicionais se fechado automaticamente)  
**📁 Seleção de Backup**: Seleção de arquivo de backup através do menu da interface original do multitool  
**🚀 Processamento em Massa**: Fluxo de trabalho otimizado para descaracterização em lote de TV boxes  
**🛠️ Dependências Corrigidas**: URLs dos repositórios Debian atualizadas para builds confiáveis

---

## ⚡ Quick Start | Início Rápido

**English:**
1. Clone this repository
2. Install dependencies: `sudo apt install multistrap squashfs-tools parted dosfstools ntfs-3g`
3. Build for your board: `sudo ./create_image.sh $board`
4. Flash the resulting image to SD card
5. Boot TV box with the SD card - automatic restore will begin after 10 seconds

**Português:**
1. Clone este repositório
2. Instale dependências: `sudo apt install multistrap squashfs-tools parted dosfstools ntfs-3g`
3. Compile para sua placa: `sudo ./create_image.sh $board`
4. Grave a imagem resultante no cartão SD
5. Inicialize a TV box com o cartão SD - o restore automático começará após 10 segundos

---

## 📦 Installation | Instalação

### Prerequisites | Pré-requisitos

**Debian-derived system required | Sistema baseado em Debian necessário**

```bash
sudo apt install multistrap squashfs-tools parted dosfstools ntfs-3g
```

### Clone Repository | Clonar Repositório

```bash
git clone https://github.com/IFSPresente/multitool
cd multitool
```

---

## 🎯 Usage | Uso

### Supported Boards | Placas Suportadas

**🔧 Rockchip SoCs:**
- **rk322x series** (RK3228, RK3229)
- **rk3288 series** 
- **rk3318 series**
- **rk3528 series**

**📺 Primary Target | Alvo Primário:** MXQ TV Boxes

### Backup File Structure | Estrutura dos Arquivos de Backup

The automatic restore system uses the same backup file structure as the original multitool. Place your backup files in the appropriate directory and select them through the multitool menu interface.

O sistema de restauração automática usa a mesma estrutura de arquivos de backup do multitool original. Coloque seus arquivos de backup no diretório apropriado e selecione-os através da interface de menu do multitool.

### Operation Modes | Modos de Operação

**🤖 Automatic Mode | Modo Automático:**
- Boot with SD card
- Wait 15 seconds total (10s + 5s after license dialog)
- System will automatically restore and power off

**🖱️ Manual Mode | Modo Manual:**
- Interrupt the countdown within 10 seconds
- Use standard multitool interface for manual backup selection
- Follow original multitool procedures

---

## 🏗️ Building | Compilação

### Build Process | Processo de Compilação

**⚠️ Root privileges required | Privilégios de root necessários**

```bash
sudo ./create_image.sh $board
```

### Available Configurations | Configurações Disponíveis

Check `sources/*.conf` for supported board configurations:

```bash
ls sources/*.conf
```

### Output | Saída

The resulting image will be available at:
```
dist-$board/multitool.img
```

---

## 🤝 Contributing | Contribuindo

### 🚧 Development Status | Status de Desenvolvimento

**⚠️ This project is currently under active development | Este projeto está atualmente em desenvolvimento ativo**

### Current Maintainer | Mantenedor Atual

**👨‍💻 Pedro Rigolin**
- Computer Science Student | Estudante de Ciência da Computação
- IFSP Salto Campus
- TVBox Project Member | Membro do Projeto TVBox
- GitHub: [@pedrohrigolin](https://github.com/pedrohrigolin)

### How to Contribute | Como Contribuir

1. **🍴 Fork** this repository
2. **🌿 Create** a feature branch (`git checkout -b feature/amazing-feature`)
3. **📝 Commit** your changes (`git commit -m 'Add amazing feature'`)
4. **🚀 Push** to the branch (`git push origin feature/amazing-feature`)
5. **📬 Open** a Pull Request

---

## 📞 Contact | Contato

### TVBox Project | Projeto TVBox

- **🏫 Institution | Instituição:** Federal Institute of São Paulo - Salto Campus | Instituto Federal de São Paulo - Campus Salto
- **📧 Email:** [projetotvbox@ifsp.edu.br](mailto:projetotvbox@ifsp.edu.br)
- **📱 Instagram:** [@projetotvbox](https://www.instagram.com/projetotvbox/)
- **🐙 GitHub Org:** [@IFSPresente](https://github.com/IFSPresente)

### Support | Suporte

For questions about this fork specifically | Para dúvidas sobre este fork especificamente:
- **🐛 Issues:** [GitHub Issues](https://github.com/IFSPresente/multitool/issues)
- **💬 Discussions:** Contact through TVBox Project channels | Contate através dos canais do Projeto TVBox

---

## 📜 License | Licença

This project maintains the same license as the original multitool project. The license is temporarily displayed during boot to align with the automatic restore functionality.

Este projeto mantém a mesma licença do projeto multitool original. A licença é exibida temporariamente durante o boot para alinhar com a funcionalidade de restore automático.

---

## 🙏 Credits | Créditos

### Original Project | Projeto Original

**🎯 Based on:** [paolosabatino/multitool](https://github.com/paolosabatino/multitool)  
**👨‍💻 Original Author:** Paolo Sabatino

### Improvements Made | Melhorias Realizadas

- **🔗 Repository URL Fix:** Updated `sources/multistrap/multistrap.conf` from `http://ftp.it.debian.org/debian` to `http://archive.debian.org/debian`
- **🤖 Automatic Restore:** Implementation of timed automatic restore functionality
- **⏱️ License Display:** Temporary license display aligned with automatic restore process

### Reported Issues | Issues Reportadas

- **🐛 Debian Repository Fix:** [Issue #8](https://github.com/paolosabatino/multitool/issues/8) on original repository

---

<div align="center">

**🐧 Made with ❤️ by the TVBox Project Team**  
**🏫 Federal Institute of São Paulo - Salto Campus**

**🐧 Feito com ❤️ pela Equipe do Projeto TVBox**  
**🏫 Instituto Federal de São Paulo - Campus Salto**

</div>