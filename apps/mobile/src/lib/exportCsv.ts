import { Platform, Share } from 'react-native';

/**
 * Hand a CSV to the user: a file download on web, the native share sheet on
 * iOS/Android (Mail, Files, Drive, Slack…). Content is produced by
 * @nforce/core `toCsv`, which neutralizes spreadsheet formula injection.
 */
export async function exportCsv(filename: string, csv: string): Promise<void> {
  if (Platform.OS === 'web' && typeof document !== 'undefined') {
    const blob = new Blob([csv], { type: 'text/csv;charset=utf-8' });
    const url = URL.createObjectURL(blob);
    const a = document.createElement('a');
    a.href = url;
    a.download = filename;
    document.body.appendChild(a);
    a.click();
    a.remove();
    setTimeout(() => URL.revokeObjectURL(url), 1000);
    return;
  }
  await Share.share({ title: filename, message: csv });
}
