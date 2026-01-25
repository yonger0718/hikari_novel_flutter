<div align="center">

  <div align="center">
    <img src="./assets/images/logo_transparent.png" alt="Logo" height="250">
  </div>

  # Hikari Novel

  <p align="center"><font>使用flutter构建的第三方轻小说文库客户端</font></p>

  <div>
    <img alt="GitHub Release" src="https://img.shields.io/github/v/release/15dd/hikari_novel_flutter?style=for-the-badge&color=%23408A23">
    <img alt="GitHub Downloads (all assets, all releases)" src="https://img.shields.io/github/downloads/15dd/hikari_novel_flutter/total?style=for-the-badge&color=%23478da7">
    <img alt="License" src="https://img.shields.io/badge/License-MIT-Green?style=for-the-badge&color=rgb(164%2C25%2C49)">
  </div>
  
</div>

## 功能
- Material Design 3风格
- 支持深浅模式切换
- 适配平板
- 支持章节缓存
- 支持查看评论与回复
- 阅读进度保存


## 支持平台
- [x] Android：支持（最低支持版本为Android 6.0），Android15测试通过
- [x] iOS：理论上支持，未测试
- [x] Windows：支持，Windows10 22H2及以上测试通过，但未对键鼠操作进行适配，处于半可用状态
- [x] MacOS：理论上支持，未测试，未对键鼠操作进行适配
- [ ] Linux：不支持
- [ ] Web：不支持

⚠️特别注意️️⚠️：当ios版本出问题时，不保证能修复，因为我没有苹果设备，所以仅保证安卓版能正常使用，但欢迎有能力的人士提pr


## 安装
本项目不提供安装包，请参考下方`编译与调试`自行编译使用


## 编译与调试
- ##### 我的开发环境
    ```
    [√] Flutter (Channel stable, 3.38.5, on Microsoft Windows [版本 10.0.26200.7623], locale zh-CN)
    [√] Windows Version (Windows 11 or higher, 25H2, 2009)
    [!] Android toolchain - develop for Android devices (Android SDK version 36.1.0)
    ! Some Android licenses not accepted. To resolve this, run: flutter doctor --android-licenses
    [X] Chrome - develop for the web (Cannot find Chrome executable at .\Google\Chrome\Application\chrome.exe)
    ! Cannot find Chrome. Try setting CHROME_EXECUTABLE to a Chrome executable.
    [√] Visual Studio - develop Windows apps (Visual Studio 生成工具 2026 18.2.0)
    [√] Connected device (3 available)
    [√] Network resources
    ```
- ##### 编译
    - Windows
        > 因使用了flutter_inappwebview框架，所以您需要确保您的电脑上安装了nuget，如没有可以使用winget进行安装`winget install Microsoft.NuGet`
    - 其他平台
        > 请自行调整


## 声明
- 本项目是个人为了兴趣以及学习移动端开发而开发的，仅用于学习和测试
- 本项目所用API均从轻小说文库官方网站和互联网收集，不提供任何破解内容
- 本项目是个人项目，与轻小说文库官方无关，请注意辨别


## 参考
- [flutter_dmzj](https://github.com/xiaoyaocz/flutter_dmzj)
- [venera](https://github.com/venera-app/venera)
- [mihon](https://github.com/mihonapp/mihon)
- [mikan_flutter](https://github.com/iota9star/mikan_flutter)
- [pilipala](https://github.com/guozhigq/pilipala)
- [PiliPalaX](https://github.com/orz12/PiliPalaX)
- [light-novel-library_Wenku8_Android](https://github.com/MewX/light-novel-library_Wenku8_Android)
- AI