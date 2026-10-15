Unicode true
Target amd64-unicode
!include "MUI2.nsh"
!include "LogicLib.nsh"
!include "WinVer.nsh"
!define APP_VERSION "0.7.2"
!define OWNER "LETHE-OWNED-INSTALL-v1"
!define APP_KEY "Software\LETHE ONE"
!define UNINSTALL_KEY "Software\Microsoft\Windows\CurrentVersion\Uninstall\LETHE ONE"
Name "LETHE ONE ${APP_VERSION}"
OutFile "${OUTPUT_FILE}"
InstallDir "$LOCALAPPDATA\Programs\LETHE ONE"
RequestExecutionLevel user
SetCompressor /SOLID lzma
SetCompressorDictSize 32
CRCCheck force
AllowSkipFiles off
ShowInstDetails show
ShowUninstDetails show
VIProductVersion "0.7.2.1"
VIAddVersionKey /LANG=1049 "ProductName" "LETHE ONE"
VIAddVersionKey /LANG=1049 "FileDescription" "Установка LETHE ONE"
VIAddVersionKey /LANG=1049 "FileVersion" "0.7.2.1"
VIAddVersionKey /LANG=1049 "ProductVersion" "0.7.2"
VIAddVersionKey /LANG=1049 "LegalCopyright" "LETHE project"
BrandingText "LETHE ONE"
Var SetupMutex
Var DeleteFailed

!define MUI_ABORTWARNING
!define MUI_WELCOMEPAGE_TITLE "Установка LETHE ONE"
!define MUI_WELCOMEPAGE_TEXT "Мастер установит LETHE для текущего пользователя и создаст ярлык в меню «Пуск».$\r$\n$\r$\nПапка: $LOCALAPPDATA\Programs\LETHE ONE$\r$\n$\r$\nСохранённые настройки и профиль будут доступны после установки. Перед обновлением отключите VPN и закройте LETHE."
!insertmacro MUI_PAGE_WELCOME
!insertmacro MUI_PAGE_COMPONENTS
!insertmacro MUI_PAGE_INSTFILES
!define MUI_FINISHPAGE_RUN "$INSTDIR\LETHE.exe"
!define MUI_FINISHPAGE_RUN_TEXT "Запустить LETHE"
!insertmacro MUI_PAGE_FINISH
!define MUI_UNCONFIRMPAGE_TEXT_TOP "Будут удалены файлы приложения и его ярлыки. Ваши настройки, профиль и журналы останутся в папке данных LETHE. Сервер на VPS не изменяется."
!insertmacro MUI_UNPAGE_CONFIRM
!insertmacro MUI_UNPAGE_INSTFILES
!insertmacro MUI_LANGUAGE "Russian"

!macro CheckRunning NAME
    System::Call 'kernel32::OpenMutexW(i 0x100000, i 0, w "${NAME}") p.r0 ?e'
    Pop $1
    ${If} $0 != 0
        System::Call 'kernel32::CloseHandle(p r0)'
        MessageBox MB_OK|MB_ICONEXCLAMATION "Отключите VPN и закройте LETHE, включая значок возле часов. Затем повторите операцию."
        Abort
    ${EndIf}
    ${If} $1 != 2
        MessageBox MB_OK|MB_ICONSTOP "Не удалось проверить состояние LETHE. Завершите сеансы LETHE и повторите операцию."
        Abort
    ${EndIf}
!macroend

!macro LockSetup
    System::Call 'kernel32::CreateMutexW(p 0, i 0, w "Local\LETHE-One-Setup") p.r0 ?e'
    Pop $1
    StrCpy $SetupMutex $0
    ${If} $0 = 0
    ${OrIf} $1 = 183
        MessageBox MB_OK|MB_ICONEXCLAMATION "Не удалось начать операцию: проверьте, не запущен ли другой установщик или удаление LETHE."
        Abort
    ${EndIf}
!macroend

!macro DefineGuard PREFIX
Function ${PREFIX}CheckStopped
    !insertmacro CheckRunning "Local\LETHE-One-GUI"
    !insertmacro CheckRunning "Local\LETHE-One-Deploy"
    !insertmacro CheckRunning "Global\LETHE-One-Action"
    IfFileExists "$LOCALAPPDATA\LETHE-One\runtime\state.json" 0 state_clear
        MessageBox MB_OK|MB_ICONEXCLAMATION "Сохранён незавершённый сеанс VPN. Откройте текущую версию LETHE, нажмите «Отключить» и закройте приложение перед продолжением."
        Abort
    state_clear:
FunctionEnd
Function ${PREFIX}CheckOwned
    IfFileExists "$INSTDIR\*.*" 0 owned_clear
    ClearErrors
    FileOpen $0 "$INSTDIR\LETHE.install-owner" r
    IfErrors not_owned
    FileRead $0 $1
    FileClose $0
    StrCmp $1 "${OWNER}" owned_clear
    not_owned:
        MessageBox MB_OK|MB_ICONSTOP "Папка $INSTDIR уже существует, но не принадлежит этому установщику. Её содержимое сохранено. Переместите прежнюю папку в другое место и повторите установку."
        Abort
    owned_clear:
FunctionEnd
!macroend
!insertmacro DefineGuard ""
!insertmacro DefineGuard "un."

Function .onInit
    SetShellVarContext current
    SetRegView 64
    ; Fixed per-user directory: never install over arbitrary /D destinations.
    StrCpy $INSTDIR "$LOCALAPPDATA\Programs\LETHE ONE"
    ${IfNot} ${AtLeastWin10}
        MessageBox MB_OK|MB_ICONSTOP "Для LETHE требуется Windows 10 или Windows 11 (64 бита)."
        Abort
    ${EndIf}
    ReadRegDWORD $0 HKLM "SOFTWARE\Microsoft\NET Framework Setup\NDP\v4\Full" "Release"
    ${If} $0 < 528040
        MessageBox MB_OK|MB_ICONSTOP "Требуется Microsoft .NET Framework 4.8. Установите его с сайта Microsoft и повторите запуск установщика."
        Abort
    ${EndIf}
    !insertmacro LockSetup
    Call CheckStopped
    Call CheckOwned
FunctionEnd

Section "LETHE и ярлык в меню «Пуск»" SecMain
    SectionIn RO
    Call CheckStopped
    Call CheckOwned
    SetOutPath "$INSTDIR"
    ClearErrors
    FileOpen $0 "$INSTDIR\LETHE.install-owner" w
    FileWrite $0 "${OWNER}"
    FileClose $0
    IfErrors install_failed
    SetOverwrite on
    !include "${GENERATED_DIR}/install-files.nsh"
    IfErrors install_failed
    WriteUninstaller "$INSTDIR\Uninstall.exe"
    CreateDirectory "$SMPROGRAMS\LETHE ONE"
    CreateShortcut "$SMPROGRAMS\LETHE ONE\LETHE ONE.lnk" "$INSTDIR\LETHE.exe"
    CreateShortcut "$SMPROGRAMS\LETHE ONE\Удалить LETHE.lnk" "$INSTDIR\Uninstall.exe"
    WriteRegStr HKCU "${APP_KEY}" "InstallDir" "$INSTDIR"
    WriteRegStr HKCU "${UNINSTALL_KEY}" "DisplayName" "LETHE ONE"
    WriteRegStr HKCU "${UNINSTALL_KEY}" "DisplayVersion" "${APP_VERSION}"
    WriteRegStr HKCU "${UNINSTALL_KEY}" "Publisher" "LETHE project"
    WriteRegStr HKCU "${UNINSTALL_KEY}" "InstallLocation" "$INSTDIR"
    WriteRegStr HKCU "${UNINSTALL_KEY}" "DisplayIcon" "$INSTDIR\LETHE.exe"
    WriteRegStr HKCU "${UNINSTALL_KEY}" "UninstallString" '$\"$INSTDIR\Uninstall.exe$\"'
    WriteRegDWORD HKCU "${UNINSTALL_KEY}" "NoModify" 1
    WriteRegDWORD HKCU "${UNINSTALL_KEY}" "NoRepair" 1
    WriteRegDWORD HKCU "${UNINSTALL_KEY}" "EstimatedSize" ${INSTALLED_KB}
    IfErrors install_failed
    Goto install_done
    install_failed:
        MessageBox MB_OK|MB_ICONSTOP "Установка не завершена. Закройте LETHE, проверьте свободное место и права записи, затем запустите установщик снова."
        Abort
    install_done:
SectionEnd

Section "Ярлык на рабочем столе" SecDesktop
    CreateShortcut "$DESKTOP\LETHE ONE.lnk" "$INSTDIR\LETHE.exe"
SectionEnd

!insertmacro MUI_FUNCTION_DESCRIPTION_BEGIN
    !insertmacro MUI_DESCRIPTION_TEXT ${SecMain} "Приложение, необходимые компоненты и ярлык в меню «Пуск»."
    !insertmacro MUI_DESCRIPTION_TEXT ${SecDesktop} "Дополнительный ярлык LETHE на рабочем столе."
!insertmacro MUI_FUNCTION_DESCRIPTION_END

Function un.onInit
    SetShellVarContext current
    SetRegView 64
    !insertmacro LockSetup
    StrCpy $0 "$LOCALAPPDATA\Programs\LETHE ONE"
    ${If} $INSTDIR != $0
        MessageBox MB_OK|MB_ICONSTOP "Удаление разрешено только из папки установки LETHE."
        Abort
    ${EndIf}
    Call un.CheckStopped
    Call un.CheckOwned
FunctionEnd

Section "Uninstall"
    Call un.CheckStopped
    Call un.CheckOwned
    StrCpy $DeleteFailed 0
    ; Generated exact file list. No recursive deletion of the application directory.
    !include "${GENERATED_DIR}/uninstall-files.nsh"
    ${If} $DeleteFailed != 0
        MessageBox MB_OK|MB_ICONEXCLAMATION "Часть файлов занята или недоступна. Закройте LETHE и повторите удаление. Запись удаления сохранена."
        Abort
    ${EndIf}
    Delete "$SMPROGRAMS\LETHE ONE\LETHE ONE.lnk"
    Delete "$SMPROGRAMS\LETHE ONE\Удалить LETHE.lnk"
    RMDir "$SMPROGRAMS\LETHE ONE"
    Delete "$DESKTOP\LETHE ONE.lnk"
    DeleteRegKey HKCU "${UNINSTALL_KEY}"
    DeleteRegKey HKCU "${APP_KEY}"
    Delete "$INSTDIR\LETHE.install-owner"
    Delete "$INSTDIR\Uninstall.exe"
    !include "${GENERATED_DIR}/uninstall-directories.nsh"
    RMDir "$INSTDIR"
SectionEnd
