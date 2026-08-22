const activeRequests = new Map();

function normalizeBaseURL(value = '') {
  const trimmed = value.trim().replace(/\/+$/, '')
    .replace(/\/(?:chat\/completions|responses|models)$/i, '');
  if (!trimmed) return 'https://api.openai.com/v1';
  return trimmed.endsWith('/v1') || trimmed.includes('/v1beta') ? trimmed : `${trimmed}/v1`;
}

function providerKind(baseURL = '', apiKey = '') {
  const value = baseURL.toLowerCase();
  if (value.includes('anthropic.com')) return 'anthropic';
  if (value.includes('generativelanguage.googleapis.com')) return 'gemini';
  if (!value && String(apiKey).startsWith('sk-ant-')) return 'anthropic';
  if (!value && String(apiKey).startsWith('AIza')) return 'gemini';
  return 'openai-compatible';
}

function usageFrom(payload = {}) {
  const usage = payload.usageMetadata || payload.usage || {};
  return {
    inputTokens: usage.input_tokens ?? usage.prompt_tokens ?? usage.promptTokenCount ?? 0,
    outputTokens: usage.output_tokens ?? usage.completion_tokens ?? usage.candidatesTokenCount ?? 0,
    cachedTokens: usage.input_tokens_details?.cached_tokens ?? usage.cache_read_input_tokens ?? usage.cachedContentTokenCount ?? 0,
    reasoningTokens: usage.output_tokens_details?.reasoning_tokens ?? 0
  };
}

async function requestAI(request, onProgress) {
  const controller = new AbortController();
  activeRequests.set(request.id, controller);
  try {
    const kind = providerKind(request.baseURL, request.apiKey);
    const result = kind === 'anthropic'
      ? await requestAnthropic(request, controller.signal, onProgress)
      : kind === 'gemini'
        ? await requestGemini(request, controller.signal, onProgress)
        : await requestOpenAICompatible(request, controller.signal, onProgress);
    if (!result.usage?.inputTokens) result.usage.inputTokens = estimateTokens(`${request.system}\n${request.messages.map(message => message.content).join('\n')}`);
    if (!result.usage?.outputTokens) result.usage.outputTokens = estimateTokens(result.text);
    return result;
  } finally {
    activeRequests.delete(request.id);
  }
}

async function requestOpenAICompatible(request, signal, onProgress) {
  const baseURL = normalizeBaseURL(request.baseURL);
  const body = {
    model: request.model,
    messages: [
      { role: 'system', content: request.system },
      ...request.messages
    ],
    max_tokens: request.maxTokens,
    stream: true,
    stream_options: { include_usage: true },
    ...(request.reasoningEffort && request.reasoningEffort !== 'none'
      ? { reasoning_effort: request.reasoningEffort }
      : {})
  };
  const send = () => fetch(`${baseURL}/chat/completions`, {
    method: 'POST',
    headers: { 'content-type': 'application/json', authorization: `Bearer ${request.apiKey}` },
    body: JSON.stringify(body),
    signal
  });
  let response = await send();
  if (!response.ok && response.status === 400) {
    const hint = await response.clone().text();
    let changed = false;
    if (/max_tokens.*(?:unsupported|not support|unknown)|unsupported.*max_tokens/i.test(hint)) {
      delete body.max_tokens; body.max_completion_tokens = request.maxTokens; changed = true;
    }
    if (/stream_options/i.test(hint)) { delete body.stream_options; changed = true; }
    if (/reasoning_effort/i.test(hint)) { delete body.reasoning_effort; changed = true; }
    if (changed) response = await send();
  }
  if (!response.ok) throw await providerError(response);
  const contentType = response.headers.get('content-type') || '';
  if (contentType.includes('application/json')) {
    const payload = await response.json();
    const text = payload.choices?.map(choice => choice.message?.content || choice.text || '').join('') || payload.output_text || '';
    if (text) onProgress?.(text);
    if (payload.choices?.some(choice => choice.finish_reason === 'length')) throw new Error('AI 达到输出上限，未返回完整答案。请改用更深的阅读模式或缩小问题范围。');
    return { text, usage: usageFrom(payload) };
  }
  if (!response.body) throw new Error('AI 服务没有返回响应流。');
  const reader = response.body.getReader();
  const decoder = new TextDecoder();
  let pending = '';
  let text = '';
  let usage = {};
  let truncated = false;
  while (true) {
    const { value, done } = await reader.read();
    if (done) break;
    pending += decoder.decode(value, { stream: true });
    const lines = pending.split(/\r?\n/);
    pending = lines.pop() || '';
    for (const line of lines) {
      if (!line.startsWith('data:')) continue;
      const raw = line.slice(5).trim();
      if (!raw || raw === '[DONE]') continue;
      let event;
      try { event = JSON.parse(raw); } catch { continue; }
      const delta = event.choices?.map(choice => choice.delta?.content || '').join('') || '';
      if (delta) {
        text += delta;
        onProgress?.(delta);
      }
      if (event.usage) usage = usageFrom(event);
      if (event.choices?.some(choice => choice.finish_reason === 'length')) truncated = true;
    }
  }
  if (truncated) throw new Error('AI 达到输出上限，未返回完整答案。请改用更深的阅读模式或缩小问题范围。');
  return { text, usage };
}

async function requestAnthropic(request, signal, onProgress) {
  const baseURL = request.baseURL.trim().replace(/\/+$/, '') || 'https://api.anthropic.com';
  const endpoint = baseURL.endsWith('/v1') ? `${baseURL}/messages` : `${baseURL}/v1/messages`;
  const response = await fetch(endpoint, {
    method: 'POST',
    headers: {
      'content-type': 'application/json',
      'x-api-key': request.apiKey,
      'anthropic-version': '2023-06-01'
    },
    body: JSON.stringify({
      model: request.model,
      system: request.system,
      messages: request.messages,
      max_tokens: request.maxTokens,
      stream: false
    }),
    signal
  });
  if (!response.ok) throw await providerError(response);
  const payload = await response.json();
  const text = (payload.content || []).filter(item => item.type === 'text').map(item => item.text).join('\n\n');
  if (text) onProgress?.(text);
  return { text, usage: usageFrom(payload) };
}

async function requestGemini(request, signal, onProgress) {
  const base = request.baseURL.trim().replace(/\/+$/, '') || 'https://generativelanguage.googleapis.com/v1beta';
  const endpoint = `${base}/models/${encodeURIComponent(request.model)}:generateContent?key=${encodeURIComponent(request.apiKey)}`;
  const response = await fetch(endpoint, {
    method: 'POST',
    headers: { 'content-type': 'application/json' },
    body: JSON.stringify({
      systemInstruction: { parts: [{ text: request.system }] },
      contents: request.messages.map(message => ({
        role: message.role === 'assistant' ? 'model' : 'user',
        parts: [{ text: message.content }]
      })),
      generationConfig: { maxOutputTokens: request.maxTokens }
    }),
    signal
  });
  if (!response.ok) throw await providerError(response);
  const payload = await response.json();
  const text = payload.candidates?.flatMap(candidate => candidate.content?.parts || []).map(part => part.text || '').join('\n\n') || '';
  if (text) onProgress?.(text);
  return { text, usage: usageFrom(payload) };
}

async function providerError(response) {
  const raw = await response.text();
  let message = raw;
  try {
    const payload = JSON.parse(raw);
    message = payload.error?.message || payload.message || raw;
  } catch {}
  const error = new Error(`AI 请求失败（${response.status}）：${message}`);
  error.status = response.status;
  return error;
}

async function listModels({ apiKey, baseURL }) {
  const kind = providerKind(baseURL, apiKey);
  if (kind === 'anthropic') {
    const base = baseURL.trim().replace(/\/+$/, '') || 'https://api.anthropic.com';
    const endpoint = base.endsWith('/v1') ? `${base}/models` : `${base}/v1/models`;
    const response = await fetch(endpoint, { headers: { 'x-api-key': apiKey, 'anthropic-version': '2023-06-01' } });
    if (response.ok) {
      const payload = await response.json();
      const models = (payload.data || []).map(item => item.id).filter(Boolean);
      if (models.length) return models;
    }
    return ['claude-sonnet-4-5', 'claude-haiku-4-5'];
  }
  if (kind === 'gemini') {
    const base = baseURL.trim().replace(/\/+$/, '') || 'https://generativelanguage.googleapis.com/v1beta';
    const response = await fetch(`${base}/models?key=${encodeURIComponent(apiKey)}`);
    if (!response.ok) throw await providerError(response);
    const payload = await response.json();
    return (payload.models || []).filter(model => model.supportedGenerationMethods?.includes('generateContent')).map(model => model.name.replace(/^models\//, ''));
  }
  const response = await fetch(`${normalizeBaseURL(baseURL)}/models`, {
    headers: { authorization: `Bearer ${apiKey}` }
  });
  if (!response.ok) throw await providerError(response);
  const payload = await response.json();
  return (payload.data || []).map(item => item.id).filter(Boolean).sort();
}

async function detectOfficialProvider(apiKey) {
  const value = String(apiKey || '').trim();
  if (!value) throw new Error('请输入 API Key。');
  const candidates = value.startsWith('sk-ant-')
    ? [{ provider: 'Anthropic', baseURL: 'https://api.anthropic.com' }]
    : value.startsWith('AIza')
      ? [{ provider: 'Google Gemini', baseURL: 'https://generativelanguage.googleapis.com/v1beta' }]
      : value.startsWith('sk-or-v1-')
        ? [{ provider: 'OpenRouter', baseURL: 'https://openrouter.ai/api/v1' }]
        : [
            { provider: 'OpenAI', baseURL: 'https://api.openai.com/v1' },
            { provider: 'AIHUBMix', baseURL: 'https://aihubmix.com/v1' },
            { provider: 'AIHUBMix', baseURL: 'https://api.aihubmix.com/v1' },
            { provider: 'DeepSeek', baseURL: 'https://api.deepseek.com' }
          ];
  let lastError;
  for (const candidate of candidates) {
    try {
      if (candidate.provider === 'OpenRouter') {
        const validation = await fetch('https://openrouter.ai/api/v1/auth/key', { headers: { authorization: `Bearer ${value}` } });
        if (!validation.ok) throw await providerError(validation);
      }
      const models = await listModels({ apiKey: value, baseURL: candidate.baseURL });
      if (models.length) return { ...candidate, models };
    } catch (error) { lastError = error; }
  }
  throw lastError || new Error('无法识别或验证这个 API Key。');
}

function estimateTokens(text = '') {
  let count = 0;
  let latin = '';
  const flush = () => { if (latin) { count += Math.max(1, Math.ceil(latin.length / 4)); latin = ''; } };
  for (const character of String(text)) {
    if (/\p{Script=Han}/u.test(character)) { flush(); count += 1; }
    else if (/[A-Za-z0-9]/.test(character)) latin += character;
    else { flush(); if (!/\s/.test(character)) count += .35; }
  }
  flush();
  return Math.ceil(count);
}

function cancelAI(id) {
  const controller = activeRequests.get(id);
  if (!controller) return false;
  controller.abort();
  return true;
}

module.exports = { requestAI, cancelAI, listModels, detectOfficialProvider, normalizeBaseURL, providerKind, usageFrom, estimateTokens };
