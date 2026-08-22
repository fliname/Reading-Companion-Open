export function markMatchesQuery(mark = {}, query = '') {
  const needle = String(query).normalize('NFKC').trim().toLocaleLowerCase('zh-CN');
  if (!needle) return true;
  return [mark.text, mark.note].some(value => String(value || '').normalize('NFKC').toLocaleLowerCase('zh-CN').includes(needle));
}
