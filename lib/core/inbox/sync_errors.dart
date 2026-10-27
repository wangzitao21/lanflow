// Shared by endpoint status and durable attachment failures.
const retryableSyncCategories = {
  'offline',
  'timeout',
  'busy',
  'source_pending',
  'paused',
  'not_ready',
};

String? syncErrorMessage(String? raw, String? category, {bool isHub = false}) {
  if (raw == null) return null;
  return switch (category) {
    'offline' || 'timeout' => '离线',
    'busy' => '对方暂时忙，稍后自动重试',
    'paused' => '对方已暂停同步，恢复后会继续',
    'not_ready' => '对方正在准备同步，稍后自动重试',
    'source_pending' => '等待附件来源设备上线',
    'authentication' => isHub ? 'NAS 连接码已失效，请重新绑定' : '连接已失效，请重新配对',
    'identity' => isHub ? 'NAS 身份与连接码不匹配' : '设备身份校验失败，请确认设备地址或重新绑定',
    'storage' => '本机存储读写失败，请检查剩余空间和权限',
    'remote_storage' => '对方存储读写失败，请检查对方的剩余空间和权限',
    'protocol' => '对方的同步响应无效或版本不兼容，请更新两端 LanFlow',
    'conflict' => '同步记录不一致，原内容已保留，请检查两端版本',
    'integrity' => '附件校验未通过，正在重新传输',
    _ => raw,
  };
}
