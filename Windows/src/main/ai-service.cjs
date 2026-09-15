const activeRequests = new Map();

const freeCompanionInstructions = '\n\n你是 Reading Companion 的虚构类伴读，主要陪读小说、戏剧和其他叙事文本。直接回答读者提出的事实问题；需要文学分析时，只做与当前问题有关的适度分析。严格依据提供的原文，不编造人物、情节、页码或作者意图；证据不足就简短说明。默认使用中文，不加载学术伴读框架，不追加碰撞问题，不强制小标题、列表或固定结构。';
const freeModeBudgetInstructions = '\n\n默认用 120–300 个汉字完成回答；简单事实问题尽量在 1–3 句内回答，文学分析最多使用三个短段。只保留直接答案和必要依据，不重复问题，不写开场白、总结或延伸提问，并在篇幅内完整结束。';

const fictionPageRangeSummaryInstructions = `请用 150–250 个汉字概括这段小说片段的主要事件和人物动态。
要求：
- 概述发生了什么（行动/事件），不要照抄原文
- 点明涉及的主要人物及其动作/态度变化
- 如果有情感转折或悬念，简要提及
- 不要评价文学质量，不要引用原文超过 20 字
- 最后一句必须完整结束`;

const fictionSummaryInitialTokenLimit = 2500;
const fictionSummaryRetryTokenLimit = 5000;

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
    if (request.companionMode === 'free') {
      request = {
        ...request,
        system: request.system || `${freeCompanionInstructions}${freeModeBudgetInstructions}`,
        cacheKey: `${request.cacheKey || request.id || ''}::companion:${request.companionMode}`
      };
    }
    const kind = providerKind(request.baseURL, request.apiKey);
    const send = candidate => kind === 'anthropic'
      ? requestAnthropic(candidate, controller.signal, onProgress)
      : kind === 'gemini'
        ? requestGemini(candidate, controller.signal, onProgress)
        : requestOpenAICompatible(candidate, controller.signal, onProgress);
    const maximumContinuations = Math.min(3, Math.max(0, Number(request.maxContinuations) || 0));
    let messages = request.messages;
    let text = '';
    let usage = { inputTokens: 0, outputTokens: 0, cachedTokens: 0, reasoningTokens: 0 };
    let continuationCount = 0;
    let truncated = false;

    for (let attempt = 0; attempt <= maximumContinuations; attempt += 1) {
      const result = await send({
        ...request,
        messages,
        // A continuation should spend its budget on completing the visible
        // answer instead of repeating another long hidden reasoning pass.
        reasoningEffort: attempt > 0 ? 'low' : request.reasoningEffort
      });
      text += result.text || '';
      usage = addUsage(usage, result.usage);
      truncated = !!result.truncated;
      if (!truncated) break;
      if (attempt >= maximumContinuations) break;
      continuationCount += 1;
      messages = [
        ...request.messages,
        ...(text ? [{ role: 'assistant', content: text }] : []),
        {
          role: 'user',
          content: text
            ? '刚才的回答因输出上限中断。请直接从中断处继续，不要重复已有内容；用更紧凑的措辞补全剩余论证，并自然结束。'
            : '刚才的推理耗尽了输出额度但没有产生可见答案。请降低内部推理篇幅，直接给出完整、紧凑且自然收束的回答。'
        }
      ];
    }
    let usedCompactRescue = false;
    if (truncated) {
      usedCompactRescue = true;
      continuationCount += 1;
      const rescue = await send({
        ...request,
        messages: [
          ...request.messages,
          ...(text ? [{ role: 'assistant', content: text }] : []),
          {
            role: 'user',
            content: '只补写尚未完成的结论并立即收束。不要重复已有内容，不再展开新分支；控制在 600 个汉字以内，确保最后一句完整结束。'
          }
        ],
        maxTokens: Math.min(1800, request.maxTokens),
        reasoningEffort: 'low'
      });
      text += rescue.text || '';
      usage = addUsage(usage, rescue.usage);
      truncated = !!rescue.truncated;
    }
    if (!usage.inputTokens) usage.inputTokens = estimateTokens(`${request.system}\n${request.messages.map(message => message.content).join('\n')}`);
    if (!usage.outputTokens) usage.outputTokens = estimateTokens(text);
    if (!text.trim()) throw new Error('AI 服务没有返回可见答案，请检查模型状态后重试。');
    return { text, usage, continuationCount, incomplete: truncated, usedCompactRescue };
  } finally {
    activeRequests.delete(request.id);
  }
}

function addUsage(total, usage = {}) {
  return {
    inputTokens: total.inputTokens + (Number(usage.inputTokens) || 0),
    outputTokens: total.outputTokens + (Number(usage.outputTokens) || 0),
    cachedTokens: total.cachedTokens + (Number(usage.cachedTokens) || 0),
    reasoningTokens: total.reasoningTokens + (Number(usage.reasoningTokens) || 0)
  };
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
    const truncated = payload.choices?.some(choice => ['length', 'max_tokens', 'max_output_tokens'].includes(choice.finish_reason));
    return { text, usage: usageFrom(payload), truncated };
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
  return { text, usage, truncated };
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
  return { text, usage: usageFrom(payload), truncated: payload.stop_reason === 'max_tokens' };
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
  const truncated = payload.candidates?.some(candidate => ['MAX_TOKENS', 'MAX_OUTPUT_TOKENS'].includes(candidate.finishReason));
  return { text, usage: usageFrom(payload), truncated };
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

async function generateFictionPageRangeSummary(request, onProgress) {
  const controller = new AbortController();
  activeRequests.set(request.id, controller);
  try {
    const kind = providerKind(request.baseURL, request.apiKey);
    const send = candidate => kind === 'anthropic'
      ? requestAnthropic(candidate, controller.signal, onProgress)
      : kind === 'gemini'
        ? requestGemini(candidate, controller.signal, onProgress)
        : requestOpenAICompatible(candidate, controller.signal, onProgress);
    const baseRequest = {
      ...request,
      system: fictionPageRangeSummaryInstructions
    };
    let text = '';
    let usage = { inputTokens: 0, outputTokens: 0, cachedTokens: 0, reasoningTokens: 0 };
    let truncated = false;
    const initial = await send({
      ...baseRequest,
      maxTokens: fictionSummaryInitialTokenLimit
    });
    text = initial.text || '';
    usage = addUsage(usage, initial.usage);
    truncated = !!initial.truncated;
    if (truncated) {
      const retry = await send({
        ...baseRequest,
        maxTokens: fictionSummaryRetryTokenLimit,
        messages: [
          ...request.messages,
          ...(text ? [{ role: 'assistant', content: text }] : []),
          {
            role: 'user',
            content: '刚才的回答因输出上限中断。请从中断处继续，不要重复已有内容，并自然结束。'
          }
        ]
      });
      text += retry.text || '';
      usage = addUsage(usage, retry.usage);
      truncated = !!retry.truncated;
    }
    if (!text.trim()) throw new Error('AI 服务没有返回可见答案，请检查模型状态后重试。');
    return { text: normalizeFictionSummary(text), usage, incomplete: truncated };
  } finally {
    activeRequests.delete(request.id);
  }
}

function normalizeFictionSummary(text = '') {
  const normalized = String(text).trim();
  const chars = [...normalized];
  let hanCount = 0;
  let cutoffIndex = -1;
  for (let i = 0; i < chars.length; i += 1) {
    if (/\p{Script=Han}/u.test(chars[i])) {
      hanCount += 1;
      if (hanCount === 250) cutoffIndex = i;
    }
  }
  if (hanCount <= 250) return normalized;
  const sentenceEnders = new Set(['。', '！', '？', '.', '!', '?']);
  let lastSentenceEnd = -1;
  for (let i = cutoffIndex; i >= 0; i -= 1) {
    if (sentenceEnders.has(chars[i])) {
      lastSentenceEnd = i;
      break;
    }
  }
  if (lastSentenceEnd >= 0) {
    return chars.slice(0, lastSentenceEnd + 1).join('');
  }
  return chars.slice(0, cutoffIndex + 1).join('');
}

module.exports = { requestAI, cancelAI, listModels, detectOfficialProvider, normalizeBaseURL, providerKind, usageFrom, estimateTokens, addUsage, generateFictionPageRangeSummary, normalizeFictionSummary, fictionPageRangeSummaryInstructions, freeCompanionInstructions, freeModeBudgetInstructions };
