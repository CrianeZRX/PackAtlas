'use strict';
const languages = { 'zh-CN':'简体中文', 'zh-TW':'繁體中文', en:'English', ja:'日本語', ko:'한국어', es:'Español' };
const dictionaries = Object.fromEntries(Object.keys(languages).map(code => [code, Object.create(null)]));
const messages = `
brandSubtitle|展卷 · 本地解压|展卷 · 本機解壓|ARCHIVE UTILITY|ローカル解凍ツール|로컬 압축 해제 도구|ARCHIVOS LOCALES
section|展卷 / PACKATLAS|展卷 / PACKATLAS|PACKATLAS / DESKTOP|PACKATLAS / デスクトップ|PACKATLAS / 데스크톱|PACKATLAS / ESCRITORIO
desk|解压工作台|解壓工作台|Archive workbench|解凍ワークベンチ|압축 해제 작업대|Mesa de extracción
history|操作记录|操作記錄|Activity log|操作履歴|작업 기록|Historial
settings|偏好设置|偏好設定|Preferences|環境設定|환경설정|Preferencias
queue|文件队列|檔案佇列|Archive queue|アーカイブ一覧|압축 파일 대기열|Cola de archivos
queueEmpty|添加压缩包即可开始。|加入壓縮檔即可開始。|Add an archive to get started.|アーカイブを追加してください。|압축 파일을 추가하세요.|Añade un archivo para empezar.
language|语言|語言|Language|言語|언어|Idioma
add|添加压缩包|加入壓縮檔|Add archives|アーカイブを追加|압축 파일 추가|Añadir archivos
diagramKicker|解包图解|解包圖解|ARCHIVE DIAGRAM|アーカイブの図解|압축 파일 도해|DIAGRAMA DEL ARCHIVO
diagramEmpty|从压缩包到文件|從壓縮檔到檔案|From archive to files|アーカイブからファイルへ|압축 파일에서 개별 파일로|Del archivo al contenido
dropTitle|拖入压缩包，或点击添加|拖入壓縮檔，或按一下加入|Drop an archive or add one above|ファイルをドロップ、または追加|압축 파일을 놓거나 위에서 추가|Suelta un archivo o añádelo arriba
dropBody|自动识别实际格式。在本机解压。|自動辨識實際格式。在本機解壓縮。|Format detection and extraction happen locally.|形式の判定と解凍はこの端末で行います。|형식 감지와 압축 해제는 이 기기에서 처리합니다.|La detección y la extracción se hacen en este equipo.
openSample|打开样例|開啟範例|Open sample|サンプルを開く|샘플 열기|Abrir ejemplo
inspect|查看内容|查看內容|Browse contents|内容を表示|내용 보기|Ver contenido
outputKicker|解压方案|解壓方案|EXTRACTION PLAN|解凍の設定|압축 해제 설정|PLAN DE EXTRACCIÓN
output|输出设置|輸出設定|Output settings|出力設定|출력 설정|Ajustes de salida
layout|目录布局|目錄配置|Folder layout|フォルダ構成|폴더 구성|Estructura de carpetas
smart|智能布局|智慧配置|Smart layout|スマート配置|스마트 배치|Organización inteligente
folder|独立文件夹|獨立資料夾|Separate folder|専用フォルダ|별도 폴더|Carpeta aparte
here|直接解压|直接解壓縮|Extract directly|直接解凍|바로 풀기|Extraer directamente
destination|保存位置|儲存位置|Save to|保存先|저장 위치|Guardar en
sourceFolder|与压缩包同目录|與壓縮檔同位置|Next to the archive|アーカイブと同じ場所|압축 파일과 같은 위치|Junto al archivo
performance|性能|效能|Performance|処理モード|성능|Rendimiento
balanced|均衡|平衡|Balanced|バランス|균형|Equilibrado
background|低占用|低負載|Low impact|低負荷|저부하|Bajo impacto
fast|速度优先|速度優先|Faster|速度優先|속도 우선|Más rápido
conflict|文件重名|檔名重複|Name conflicts|名前の競合|이름 충돌|Nombres duplicados
rename|自动重命名|自動重新命名|Rename automatically|自動で名前を変更|자동 이름 변경|Renombrar automáticamente
skip|跳过同名文件|略過同名檔案|Skip existing files|既存ファイルをスキップ|기존 파일 건너뛰기|Omitir archivos existentes
extract|开始解压|開始解壓縮|Extract|解凍する|압축 풀기|Extraer
test|测试完整性|測試完整性|Test integrity|整合性を確認|무결성 검사|Comprobar integridad
recent|最近操作|近期操作|Recent activity|最近の操作|최근 작업|Actividad reciente
seeHistory|全部记录 →|所有記錄 →|All activity →|履歴を見る →|전체 기록 →|Ver historial →
noHistory|解压和完整性测试的结果会显示在这里。|解壓縮與完整性測試結果會顯示於此。|Extraction and integrity test results appear here.|解凍や整合性チェックの結果がここに表示されます。|압축 해제 및 무결성 검사 결과가 여기에 표시됩니다.|Aquí verás los resultados de extracción y comprobación.
clearHistory|清除记录|清除記錄|Clear history|履歴を消去|기록 지우기|Borrar historial
confirmClear|清除本机的操作记录？|清除本機的操作記錄？|Clear local activity history?|この端末の操作履歴を消去しますか？|이 기기의 작업 기록을 지울까요?|¿Borrar el historial local?
defaults|解压偏好|解壓偏好|Extraction preferences|解凍の環境設定|압축 해제 기본 설정|Preferencias de extracción
encoding|文件名编码|檔名編碼|Filename encoding|ファイル名の文字コード|파일 이름 인코딩|Codificación de nombres
automatic|自动识别|自動辨識|Automatic|自動判定|자동 감지|Automática
ignoreMac|忽略 macOS 附加元数据|忽略 macOS 附加中繼資料|Ignore macOS metadata|macOS の付加メタデータを無視|macOS 부가 메타데이터 무시|Ignorar metadatos de macOS
engine|解码引擎|解碼引擎|DECODING ENGINE|解凍エンジン|압축 해제 엔진|MOTOR DE EXTRACCIÓN
nativeNote|使用原生引擎与 7-Zip，包含 ALZ、EGG、ISZ 等既有兼容模块。|使用原生引擎與 7-Zip，內含 ALZ、EGG、ISZ 等相容模組。|Native engine and 7-Zip, including the existing ALZ, EGG and ISZ adapters.|ネイティブエンジンと 7-Zip を使い、ALZ・EGG・ISZ などに対応します。|네이티브 엔진과 7-Zip을 사용하며 ALZ, EGG, ISZ 등과 호환됩니다.|Motor nativo y 7-Zip, con los adaptadores existentes para ALZ, EGG e ISZ.
portableNote|使用 7-Zip。仅 macOS 提供原生少见格式模块。|使用 7-Zip。原生少見格式模組僅供 macOS 使用。|Uses 7-Zip. The uncommon-format adapters are available on macOS.|7-Zip を使用します。特殊形式のアダプターは macOS で利用できます。|7-Zip을 사용합니다. 희귀 형식 모듈은 macOS에서 사용할 수 있습니다.|Usa 7-Zip. Los adaptadores para formatos poco comunes están disponibles en macOS.
previewNote|这是界面预览。请打开桌面应用处理本地文件。|這是介面預覽。請開啟桌面應用程式處理本機檔案。|Interface preview. Open the desktop app to process local files.|画面プレビューです。ファイルの処理はデスクトップアプリで行えます。|화면 미리보기입니다. 파일을 처리하려면 데스크톱 앱을 여세요.|Vista previa. Abre la aplicación de escritorio para procesar archivos.
ready|就绪|就緒|Ready|準備完了|준비 완료|Listo
archive|压缩包|壓縮檔|Archives|アーカイブ|압축 파일|Archivos
doneCount|已完成|已完成|Completed|完了|완료|Completados
bytes|已解压|已解壓縮|Extracted|解凍済み|해제됨|Extraídos
running|处理中|處理中|Working|処理中|처리 중|En curso
queued|待处理|待處理|Pending|待機中|대기 중|Pendiente
done|完成|完成|Done|完了|완료|Completado
failed|失败|失敗|Failed|失敗|실패|Error
cancelled|已取消|已取消|Cancelled|キャンセル済み|취소됨|Cancelado
cancel|取消|取消|Cancel|キャンセル|취소|Cancelar
remove|移出队列|移出佇列|Remove from queue|一覧から削除|대기열에서 제거|Quitar de la cola
openOutput|显示文件|顯示檔案|Show files|ファイルを表示|파일 표시|Mostrar archivos
tested|校验通过|校驗通過|Integrity OK|整合性 OK|무결성 확인|Integridad correcta
more|加载更多|載入更多|Load more|さらに読み込む|더 불러오기|Cargar más
search|搜索已加载的文件|搜尋已載入的檔案|Search loaded files|読み込んだファイルを検索|불러온 파일 검색|Buscar archivos cargados
extractSelected|解压所选文件|解壓縮所選檔案|Extract selected|選択項目を解凍|선택 항목 풀기|Extraer selección
password|压缩包密码|壓縮檔密碼|Archive password|アーカイブのパスワード|압축 파일 비밀번호|Contraseña del archivo
wrongPassword|密码错误，请重试。|密碼錯誤，請重試。|Incorrect password. Try again.|パスワードが違います。もう一度お試しください。|비밀번호가 올바르지 않습니다. 다시 시도하세요.|Contraseña incorrecta. Inténtalo de nuevo.
continue|继续|繼續|Continue|続ける|계속|Continuar
operationFailed|操作失败。|操作失敗。|Operation failed.|処理に失敗しました。|작업에 실패했습니다.|La operación ha fallado.
engineMissing|未找到 7-Zip 解码器。|找不到 7-Zip 解碼器。|The 7-Zip decoder is missing.|7-Zip エンジンが見つかりません。|7-Zip 엔진을 찾을 수 없습니다.|No se encontró el motor 7-Zip.
unsupported|此格式需 macOS 的原生解码模块。|此格式需 macOS 的原生解碼模組。|This format requires a native macOS decoder.|この形式には macOS のネイティブエンジンが必要です。|이 형식에는 macOS 네이티브 엔진이 필요합니다.|Este formato requiere un decodificador nativo de macOS.
unsafe|压缩包包含无法安全写入的条目。|壓縮檔含有無法安全寫入的項目。|The archive contains an entry that cannot be written safely.|安全に書き込めない項目があります。|안전하게 쓸 수 없는 항목이 있습니다.|El archivo contiene una entrada que no se puede escribir de forma segura.
notFound|找不到文件或目标目录。|找不到檔案或目標資料夾。|The file or destination no longer exists.|ファイルまたは保存先が見つかりません。|파일이나 저장 위치를 찾을 수 없습니다.|Ya no existe el archivo o la carpeta de destino.
loading|正在读取压缩包…|正在讀取壓縮檔…|Reading archive…|アーカイブを読み込み中…|압축 파일을 읽는 중…|Leyendo el archivo…
empty|没有匹配的文件。|沒有符合的檔案。|No matching files.|該当するファイルがありません。|일치하는 파일이 없습니다.|No hay archivos que coincidan.
reset|恢复默认位置|恢復預設位置|Reset destination|保存先をリセット|저장 위치 초기화|Restablecer destino
close|关闭|關閉|Close|閉じる|닫기|Cerrar
preview|界面预览|介面預覽|Interface preview|画面プレビュー|화면 미리보기|Vista previa
`.trim();
for (const line of messages.split('\n')) {
  const [key, ...values] = line.split('|');
  if (values.length !== Object.keys(languages).length) throw new Error('Translation count: ' + key);
  Object.keys(languages).forEach((code, index) => { dictionaries[code][key] = values[index]; });
}
function systemLanguage(code) {
  const value = (code || '').toLowerCase();
  if (/^zh-(tw|hk|mo|hant)/.test(value)) return 'zh-TW';
  if (value.startsWith('zh')) return 'zh-CN';
  const base = value.split('-')[0];
  return Object.hasOwn(languages, base) ? base : 'en';
}
