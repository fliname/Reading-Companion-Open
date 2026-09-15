/**
 * LibraryView — renderer-process port of the macOS BookshelfSheet (ContentView.swift).
 *
 * Renders a bookshelf inside a <dialog> element: a left sidebar with fixed
 * book-type filters and user folders, plus a right grid of book cards.
 * Supports batch selection, moving books to folders, setting the fiction /
 * nonfiction category, deleting cached projects, cover rendering via
 * BookCoverRenderer, and drag-and-drop of books between folders.
 */

import { BookCoverRenderer } from './book-cover.mjs';

const FILTER_ALL = 'all';

const CATEGORY_BADGES = {
  nonfiction: { label: '非虚构', className: 'badge-nonfiction' },
  fiction: { label: '虚构', className: 'badge-fiction' },
};

const CATEGORY_MARKER = {
  nonfiction: 'var(--accent)',
  fiction: 'var(--red)',
};

function escapeHTML(value = '') {
  const node = document.createElement('div');
  node.textContent = String(value ?? '');
  return node.innerHTML;
}

function isDataURL(value) {
  return typeof value === 'string' && value.startsWith('data:');
}

function el(tag, className, text) {
  const node = document.createElement(tag);
  if (className) node.className = className;
  if (text != null) node.textContent = text;
  return node;
}

export class LibraryView {
  /**
   * @param {HTMLDialogElement} dialogEl the bookshelf dialog element
   */
  constructor(dialogEl) {
    this.dialogEl = dialogEl;
    this.projects = [];
    this.folders = [];
    this.expandedFolderIDs = new Set();
    this.selectedProjectIDs = new Set();
    this.isSelecting = false;
    this.activeFilter = { type: FILTER_ALL };

    this._handlers = {
      openBook: null,
      createFolder: null,
      moveProject: null,
      setCategory: null,
      deleteProjects: null,
      deleteFolder: null,
    };

    this._bound = {
      onClick: this._onClick.bind(this),
      onDragStart: this._onDragStart.bind(this),
      onDragOver: this._onDragOver.bind(this),
      onDragLeave: this._onDragLeave.bind(this),
      onDrop: this._onDrop.bind(this),
      onContextMenu: this._onContextMenu.bind(this),
    };

    this._build();
    this._attach();
  }

  // ---- public API ----

  /**
   * Render the full bookshelf.
   * @param {Array<{sourcePath:string,title:string,lastOpenedAt:number,available:boolean,category:string|null,folderID:string|null,coverPath:string|null}>} projects
   * @param {Array<{id:string,name:string,parentID:string|null}>} folders
   */
  render(projects, folders) {
    this.projects = Array.isArray(projects) ? projects : [];
    this.folders = Array.isArray(folders) ? folders : [];
    if (this.activeFilter.folderID && !this._folderExists(this.activeFilter.folderID)) {
      this.activeFilter = { type: FILTER_ALL };
    }
    this._populateMoveMenu();
    this._renderSidebar();
    this._renderGrid();
  }

  /** @param {(project) => void} callback */
  onOpenBook(callback) { this._handlers.openBook = callback; }

  /** @param {() => void} callback */
  onCreateFolder(callback) { this._handlers.createFolder = callback; }

  /** @param {(projects, folderID, included) => void} callback */
  onMoveProject(callback) { this._handlers.moveProject = callback; }

  /** @param {(projects, category) => void} callback */
  onSetCategory(callback) { this._handlers.setCategory = callback; }

  /** @param {(projects) => void} callback */
  onDeleteProjects(callback) { this._handlers.deleteProjects = callback; }

  /** @param {(folder) => void} callback */
  onDeleteFolder(callback) { this._handlers.deleteFolder = callback; }

  /** Remove all event listeners and clear the dialog. */
  destroy() {
    this._detach();
    this.dialogEl.replaceChildren();
    this.projects = [];
    this.folders = [];
    this.selectedProjectIDs.clear();
    this.expandedFolderIDs.clear();
  }

  // ---- structure ----

  _build() {
    this.dialogEl.replaceChildren();

    const header = el('header', 'bookshelf-header');
    this.titleEl = el('h2', null, '书架');
    header.append(this.titleEl);
    this._buildHeaderButtons(header);
    this.dialogEl.append(header);

    const layout = el('div', 'bookshelf-layout');
    this.sidebarEl = el('aside', 'bookshelf-sidebar');
    this.gridWrapEl = el('section', 'bookshelf-main');
    layout.append(this.sidebarEl, this.gridWrapEl);
    this.dialogEl.append(layout);
  }

  _buildHeaderButtons(header) {
    const actions = el('div', 'bookshelf-actions');

    this.newFolderBtn = el('button', 'tool-button', '新建文件夹');
    this.newFolderBtn.dataset.action = 'new-folder';
    actions.append(this.newFolderBtn);

    this.selectBtn = el('button', 'tool-button', '批量管理');
    this.selectBtn.dataset.action = 'toggle-select';
    actions.append(this.selectBtn);

    this.batchToolbar = el('div', 'batch-toolbar hidden');
    this.batchToolbar.append(this._buildBatchControls());
    actions.append(this.batchToolbar);

    this.countEl = el('span', 'bookshelf-count');
    actions.append(this.countEl);

    const doneBtn = el('button', 'tool-button', '完成');
    doneBtn.dataset.action = 'done';
    actions.append(doneBtn);

    header.append(actions);
  }

  _buildBatchControls() {
    const wrap = el('div', 'batch-controls');

    this.selectAllBtn = el('button', 'tool-button', '全选');
    this.selectAllBtn.dataset.action = 'select-all';
    wrap.append(this.selectAllBtn);

    // Move to folder menu
    this.moveMenu = el('select', 'folder-move-menu');
    this.moveMenu.dataset.action = 'move-selected';
    this.moveMenu.append(new Option('整理到文件夹…', ''));
    wrap.append(this.moveMenu);

    this.removeFolderBtn = el('button', 'tool-button hidden', '移出此文件夹');
    this.removeFolderBtn.dataset.action = 'remove-from-folder';
    wrap.append(this.removeFolderBtn);

    // Set category menu
    this.categoryMenu = el('select', 'category-menu');
    this.categoryMenu.dataset.action = 'categorize-selected';
    this.categoryMenu.append(new Option('修改分类…', ''));
    this.categoryMenu.append(new Option('非虚构', 'nonfiction'));
    this.categoryMenu.append(new Option('虚构', 'fiction'));
    wrap.append(this.categoryMenu);

    this.deleteBtn = el('button', 'tool-button danger', '删除');
    this.deleteBtn.dataset.action = 'delete-selected';
    wrap.append(this.deleteBtn);

    return wrap;
  }

  _renderSidebar() {
    this.sidebarEl.replaceChildren();
    const tree = el('nav', 'folder-tree');

    tree.append(this._sidebarItem('全部书籍', FILTER_ALL, 'books'));

    const categorySection = el('div', 'folder-section-label', '书籍类型');
    tree.append(categorySection);
    tree.append(this._categoryItem('非虚构类', 'nonfiction', 'nonfiction'));
    tree.append(this._categoryItem('虚构类', 'fiction', 'fiction'));

    const roots = this.folders
      .filter(f => f.parentID == null)
      .sort((a, b) => a.name.localeCompare(b.name));
    if (roots.length) {
      const section = el('div', 'folder-section-label', '文件夹');
      tree.append(section);
      roots.forEach(folder => {
        tree.append(this._folderNode(folder, 0));
        this._appendFolderChildren(tree, folder, 0);
      });
    }

    this.sidebarEl.append(tree);
  }

  _appendFolderChildren(container, folder, depth) {
    if (!this.expandedFolderIDs.has(folder.id)) return;
    const children = this.folders
      .filter(f => f.parentID === folder.id)
      .sort((a, b) => a.name.localeCompare(b.name));
    children.forEach(child => {
      container.append(this._folderNode(child, depth + 1));
      this._appendFolderChildren(container, child, depth + 1);
    });
  }

  _sidebarItem(label, type, marker) {
    const item = el('div', 'folder-item');
    item.dataset.filterType = type;
    if (this._filterMatches(type, null)) item.classList.add('active');
    item.innerHTML =
      `<span class="folder-icon" data-marker="${marker}"></span>` +
      `<span class="folder-label">${escapeHTML(label)}</span>`;
    return item;
  }

  _categoryItem(label, category, marker) {
    const item = this._sidebarItem(label, 'category', marker);
    item.dataset.category = category;
    if (this.activeFilter.type === 'category' && this.activeFilter.category === category) item.classList.add('active');
    else item.classList.remove('active');
    return item;
  }

  _folderNode(folder, depth) {
    const hasChildren = this.folders.some(f => f.parentID === folder.id);
    const isExpanded = this.expandedFolderIDs.has(folder.id);
    const count = this._projectsInFolder(folder.id).length;

    const node = el('div', 'folder-item folder-entry');
    node.dataset.folderId = folder.id;
    node.style.paddingLeft = `${10 + depth * 16}px`;
    if (this._filterMatches('folder', folder.id)) node.classList.add('active');

    const caret = el('span', 'folder-caret');
    if (hasChildren) {
      caret.classList.add('toggle');
      caret.classList.toggle('expanded', isExpanded);
      caret.dataset.action = 'toggle-folder';
    }
    node.append(caret);

    node.append(el('span', 'folder-icon', ''));
    node.append(el('span', 'folder-label', folder.name));
    node.append(el('span', 'folder-count', String(count)));
    if (this.isSelecting) {
      const remove = el('button', 'folder-delete', '删除');
      remove.title = '删除文件夹，书籍仍保留在书架';
      remove.setAttribute('aria-label', `删除文件夹“${folder.name}”`);
      remove.onclick = event => {
        event.stopPropagation();
        if (!confirm(`删除文件夹“${folder.name}”？\n\n只删除文件夹；其中的书仍保留在书架中。`)) return;
        if (this.activeFilter.folderID === folder.id) this.activeFilter = { type: FILTER_ALL };
        this._handlers.deleteFolder?.(folder);
      };
      node.append(remove);
    }

    return node;
  }

  _renderGrid() {
    this.gridWrapEl.replaceChildren();
    const visible = this._filteredProjects();
    this.countEl.textContent = `${visible.length} 本`;

    if (!this.projects.length) {
      this.gridWrapEl.append(this._emptyState('书架还是空的', '打开 PDF、EPUB、AZW3 或 MOBI 后，书籍会以封面形式保存在这里。'));
      return;
    }
    if (!visible.length) {
      this.gridWrapEl.append(this._emptyState('这个文件夹是空的', ''));
      return;
    }

    const grid = el('div', 'book-grid');
    visible
      .slice()
      .sort((a, b) => (b.lastOpenedAt || 0) - (a.lastOpenedAt || 0))
      .forEach(project => grid.append(this._bookCard(project)));
    this.gridWrapEl.append(grid);

    this._renderCovers(visible);
    this._refreshBatchToolbar();
  }

  _bookCard(project) {
    const card = el('article', 'book-card');
    card.dataset.sourcePath = project.sourcePath;
    card.draggable = true;
    if (!project.available) card.classList.add('unavailable');
    if (this.selectedProjectIDs.has(project.sourcePath)) card.classList.add('selected');

    const coverWrap = el('div', 'book-cover');
    const canvas = document.createElement('canvas');
    canvas.className = 'book-cover-canvas';
    canvas.width = 135;
    canvas.height = 190;
    canvas.dataset.sourcePath = project.sourcePath;
    canvas.dataset.title = project.title;
    coverWrap.append(canvas);

    if (this.isSelecting) {
      const check = el('span', 'book-select-mark');
      check.textContent = this.selectedProjectIDs.has(project.sourcePath) ? '✓' : '';
      coverWrap.append(check);
    } else if (!project.available) {
      coverWrap.append(el('span', 'book-missing-mark', '?'));
    }
    card.append(coverWrap);

    const meta = el('div', 'book-meta');
    const titleRow = el('div', 'book-title-row');
    const dot = el('span', 'category-dot');
    dot.style.background = CATEGORY_MARKER[project.category] || 'var(--muted)';
    titleRow.append(dot, el('span', 'book-title', project.title));
    meta.append(titleRow);

    const badgeInfo = CATEGORY_BADGES[project.category];
    meta.append(el(
      'span',
      `book-badge ${badgeInfo ? badgeInfo.className : 'badge-none'}`,
      badgeInfo ? badgeInfo.label : '未分类'
    ));
    card.append(meta);

    return card;
  }

  async _renderCovers(projects) {
    for (const project of projects) {
      const canvas = this.gridWrapEl.querySelector(
        `.book-cover-canvas[data-source-path="${CSS.escape(project.sourcePath)}"]`
      );
      if (!canvas) continue;
      try {
        const options = { title: project.title };
        if (project.coverPath && isDataURL(project.coverPath)) {
          options.imageData = project.coverPath;
        }
        await BookCoverRenderer.render(canvas, options);
      } catch {
        // BookCoverRenderer already draws a fallback on failure.
      }
    }
  }

  _emptyState(title, message) {
    const state = el('div', 'bookshelf-empty');
    state.append(el('p', 'bookshelf-empty-title', title));
    if (message) state.append(el('p', 'bookshelf-empty-message', message));
    return state;
  }

  // ---- data helpers ----

  _folderExists(folderID) {
    return this.folders.some(f => f.id === folderID);
  }

  _projectsInFolder(folderID) {
    return this.projects.filter(p => this._folderIDs(p).includes(folderID));
  }

  _uncategorizedProjects() {
    return this.projects.filter(p => p.category !== 'fiction' && p.category !== 'nonfiction');
  }

  _folderIDs(project) {
    return [...new Set([
      ...(Array.isArray(project.folderIDs) ? project.folderIDs : []),
      ...(project.folderID ? [project.folderID] : [])
    ])];
  }

  _filteredProjects() {
    switch (this.activeFilter.type) {
      case FILTER_ALL:
        return this.projects.slice();
      case 'folder':
        return this._projectsInFolder(this.activeFilter.folderID);
      case 'category':
        return this.projects.filter(p => p.category === this.activeFilter.category);
      default:
        return this.projects.slice();
    }
  }

  _filterMatches(type, folderID) {
    if (type !== this.activeFilter.type) return false;
    if (type === 'folder') return this.activeFilter.folderID === folderID;
    return true;
  }

  _selectedProjects() {
    return this.projects.filter(p => this.selectedProjectIDs.has(p.sourcePath));
  }

  // ---- events ----

  _attach() {
    this.dialogEl.addEventListener('click', this._bound.onClick);
    this.dialogEl.addEventListener('dragstart', this._bound.onDragStart);
    this.dialogEl.addEventListener('dragover', this._bound.onDragOver);
    this.dialogEl.addEventListener('dragleave', this._bound.onDragLeave);
    this.dialogEl.addEventListener('drop', this._bound.onDrop);
    this.dialogEl.addEventListener('contextmenu', this._bound.onContextMenu);
  }

  _detach() {
    this.dialogEl.removeEventListener('click', this._bound.onClick);
    this.dialogEl.removeEventListener('dragstart', this._bound.onDragStart);
    this.dialogEl.removeEventListener('dragover', this._bound.onDragOver);
    this.dialogEl.removeEventListener('dragleave', this._bound.onDragLeave);
    this.dialogEl.removeEventListener('drop', this._bound.onDrop);
    this.dialogEl.removeEventListener('contextmenu', this._bound.onContextMenu);
  }

  _onClick(event) {
    if (!event.target.closest('.bookshelf-context-menu')) this._closeContextMenu();
    const target = event.target;
    const actionEl = target.closest('[data-action]');
    const action = actionEl?.dataset.action;
    const folderCaret = target.closest('.folder-caret.toggle');

    if (action === 'done') {
      this.dialogEl.close();
      return;
    }
    if (action === 'new-folder') {
      this._handlers.createFolder?.();
      return;
    }
    if (action === 'toggle-select') {
      this._toggleSelecting();
      return;
    }
    if (action === 'select-all') {
      this._selectAllVisible();
      return;
    }
    if (action === 'move-selected' && target.tagName === 'SELECT') {
      const folderID = target.value;
      if (folderID) this._organizeSelected(folderID);
      target.value = '';
      return;
    }
    if (action === 'categorize-selected' && target.tagName === 'SELECT') {
      const category = target.value;
      if (category) this._categorizeSelected(category);
      target.value = '';
      return;
    }
    if (action === 'delete-selected') {
      this._requestDelete([...this.selectedProjectIDs]);
      return;
    }
    if (action === 'remove-from-folder') {
      const folderID = this.activeFilter.folderID;
      if (folderID) this._organizeSelected(folderID, false);
      return;
    }
    if (action === 'toggle-folder') {
      const folderID = folderCaret.closest('[data-folder-id]')?.dataset.folderId;
      if (folderID) this._toggleFolderExpanded(folderID);
      return;
    }

    const folderItem = target.closest('.folder-item');
    if (folderItem && !folderCaret) {
      this._selectFilterFromItem(folderItem);
      return;
    }

    const card = target.closest('.book-card');
    if (card) {
      const sourcePath = card.dataset.sourcePath;
      const project = this.projects.find(p => p.sourcePath === sourcePath);
      if (!project) return;
      if (this.isSelecting) {
        this._toggleSelection(sourcePath);
      } else if (project.available) {
        this._handlers.openBook?.(project);
      }
    }
  }

  _selectFilterFromItem(item) {
    const type = item.dataset.filterType;
    if (type === FILTER_ALL) {
      this.activeFilter = { type };
    } else if (type === 'category' && item.dataset.category) {
      this.activeFilter = { type: 'category', category: item.dataset.category };
    } else if (item.dataset.folderId) {
      this.activeFilter = { type: 'folder', folderID: item.dataset.folderId };
    } else {
      return;
    }
    this._renderSidebar();
    this._renderGrid();
  }

  _toggleFolderExpanded(folderID) {
    if (this.expandedFolderIDs.has(folderID)) {
      this.expandedFolderIDs.delete(folderID);
    } else {
      this.expandedFolderIDs.add(folderID);
    }
    this._renderSidebar();
  }

  _toggleSelecting() {
    this.isSelecting = !this.isSelecting;
    if (!this.isSelecting) this.selectedProjectIDs.clear();
    this.selectBtn.textContent = this.isSelecting ? '取消' : '批量管理';
    this.batchToolbar.classList.toggle('hidden', !this.isSelecting);
    this._renderSidebar();
    this._renderGrid();
  }

  _toggleSelection(sourcePath) {
    if (this.selectedProjectIDs.has(sourcePath)) {
      this.selectedProjectIDs.delete(sourcePath);
    } else {
      this.selectedProjectIDs.add(sourcePath);
    }
    this._refreshSelectionMarks();
    this._refreshBatchToolbar();
  }

  _selectAllVisible() {
    const visible = this._filteredProjects();
    const visibleIDs = visible.map(p => p.sourcePath);
    const allSelected = visibleIDs.length > 0 && visibleIDs.every(id => this.selectedProjectIDs.has(id));
    if (allSelected) {
      visibleIDs.forEach(id => this.selectedProjectIDs.delete(id));
    } else {
      visibleIDs.forEach(id => this.selectedProjectIDs.add(id));
    }
    this.selectAllBtn.textContent = allSelected ? '全选' : '取消全选';
    this._refreshSelectionMarks();
    this._refreshBatchToolbar();
  }

  _refreshSelectionMarks() {
    this.gridWrapEl.querySelectorAll('.book-card').forEach(card => {
      const selected = this.selectedProjectIDs.has(card.dataset.sourcePath);
      card.classList.toggle('selected', selected);
      const mark = card.querySelector('.book-select-mark');
      if (mark) mark.textContent = selected ? '✓' : '';
    });
  }

  _refreshBatchToolbar() {
    const count = this.selectedProjectIDs.size;
    this.deleteBtn.textContent = count > 0 ? `删除 (${count})` : '删除';
    this.deleteBtn.disabled = count === 0;
    this.moveMenu.disabled = count === 0 || this.folders.length === 0;
    this.categoryMenu.disabled = count === 0;
    const inFolder = this.activeFilter.type === 'folder';
    this.removeFolderBtn.classList.toggle('hidden', !inFolder);
    this.removeFolderBtn.disabled = count === 0 || !inFolder;
  }

  _populateMoveMenu() {
    if (!this.moveMenu) return;
    this.moveMenu.innerHTML = '';
    this.moveMenu.append(new Option('整理到文件夹…', ''));
    this.folders
      .slice()
      .sort((a, b) => a.name.localeCompare(b.name))
      .forEach(folder => this.moveMenu.append(new Option(folder.name, folder.id)));
  }

  _organizeSelected(folderID, included = true) {
    const selected = this._selectedProjects();
    if (!selected.length) return;
    this._handlers.moveProject?.(selected, folderID, included);
    if (included) this.activeFilter = { type: 'folder', folderID };
    this._finishBatchAction();
  }

  _categorizeSelected(category) {
    const selected = this._selectedProjects();
    if (!selected.length) return;
    this._handlers.setCategory?.(selected, category);
    this.activeFilter = { type: 'category', category };
    this._finishBatchAction();
  }

  _finishBatchAction() {
    this.selectedProjectIDs.clear();
    this.isSelecting = false;
    this.selectBtn.textContent = '批量管理';
    this.batchToolbar.classList.add('hidden');
    this._renderSidebar();
  }

  _requestDelete(sourcePaths) {
    if (!sourcePaths.length) return;
    const count = sourcePaths.length;
    const message = count > 1
      ? `删除所选的 ${count} 本书及其全部缓存？`
      : '删除这本书及其全部缓存？';
    if (!confirm(`${message}\n\n阅读进度、目录、概要、人物、划线、批注、AI 对话及排版/OCR/索引缓存都会清除。原始文档和 Obsidian 笔记不会被删除。`)) return;
    const targets = this.projects.filter(p => sourcePaths.includes(p.sourcePath));
    this._handlers.deleteProjects?.(targets);
    sourcePaths.forEach(id => this.selectedProjectIDs.delete(id));
  }

  // ---- per-book and folder context menus ----

  _onContextMenu(event) {
    const card = event.target.closest?.('.book-card');
    if (!card) return;
    event.preventDefault();
    event.stopPropagation();
    if (card) {
      const project = this.projects.find(item => item.sourcePath === card.dataset.sourcePath);
      if (project) this._showProjectContextMenu(project, event.clientX, event.clientY);
      return;
    }
  }

  _showProjectContextMenu(project, x, y) {
    const menu = el('div', 'bookshelf-context-menu');
    const open = el('button', null, project.available ? '打开' : '原文件已移动或删除');
    open.disabled = !project.available;
    open.onclick = () => { this._closeContextMenu(); this._handlers.openBook?.(project); };
    menu.append(open, el('div', 'context-menu-separator'), el('div', 'context-menu-label', '所在文件夹'));
    if (!this.folders.length) menu.append(el('div', 'context-menu-empty', '还没有文件夹'));
    for (const folder of this.folders.slice().sort((a, b) => a.name.localeCompare(b.name))) {
      const included = this._folderIDs(project).includes(folder.id);
      const button = el('button', null, `${included ? '✓' : '＋'} ${folder.name}`);
      button.onclick = () => {
        this._closeContextMenu();
        this._handlers.moveProject?.([project], folder.id, !included);
      };
      menu.append(button);
    }
    const remove = el('button', 'danger', '删除缓存');
    remove.onclick = () => { this._closeContextMenu(); this._requestDelete([project.sourcePath]); };
    menu.append(el('div', 'context-menu-separator'), remove);
    this._placeContextMenu(menu, x, y);
  }

  _placeContextMenu(menu, x, y) {
    this._closeContextMenu();
    menu.style.left = `${x}px`;
    menu.style.top = `${y}px`;
    this.dialogEl.append(menu);
    const bounds = menu.getBoundingClientRect();
    menu.style.left = `${Math.max(8, Math.min(x, window.innerWidth - bounds.width - 8))}px`;
    menu.style.top = `${Math.max(8, Math.min(y, window.innerHeight - bounds.height - 8))}px`;
  }

  _closeContextMenu() {
    this.dialogEl.querySelector('.bookshelf-context-menu')?.remove();
  }

  // ---- drag and drop ----

  _onDragStart(event) {
    const card = event.target.closest?.('.book-card');
    if (!card) return;
    event.dataTransfer.effectAllowed = 'move';
    event.dataTransfer.setData('text/reading-companion-book', card.dataset.sourcePath);
    card.classList.add('dragging');
  }

  _onDragOver(event) {
    const folderItem = event.target.closest?.('.folder-entry');
    if (!folderItem) return;
    event.preventDefault();
    event.dataTransfer.dropEffect = 'move';
    folderItem.classList.add('drop-over');
  }

  _onDragLeave(event) {
    const folderItem = event.target.closest?.('.folder-entry');
    if (folderItem) folderItem.classList.remove('drop-over');
  }

  _onDrop(event) {
    event.preventDefault();
    this.sidebarEl.querySelectorAll('.drop-over').forEach(node => node.classList.remove('drop-over'));
    const folderItem = event.target.closest?.('.folder-entry');
    if (!folderItem) return;
    const folderID = folderItem.dataset.folderId;
    const sourcePath = event.dataTransfer.getData('text/reading-companion-book');
    if (!folderID || !sourcePath) return;
    const project = this.projects.find(p => p.sourcePath === sourcePath);
    if (project) this._handlers.moveProject?.([project], folderID, true);
  }
}

export default LibraryView;
