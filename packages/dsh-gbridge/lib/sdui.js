import { GbridgeError, isPlainObject } from './http-util.js';

/**
 * Minimal SDUI v1 registry allowing `dsh-gbridge` (and third-party Cordis plugins
 * via `ctx.inject(['gbridge'])`) to ship declarative native Flutter views without
 * updating the compiled Android APK.
 */
export class SduiRegistry {
  constructor() {
    this.surfaces = new Map(); // id -> { id, title, subtitle, icon, placement, render, onAction }
  }

  register(surface) {
    if (!isPlainObject(surface) || typeof surface.id !== 'string' || !surface.id.trim()) {
      throw new Error('gbridge.sdui: surface requires non-empty string id');
    }
    if (typeof surface.render !== 'function') {
      throw new Error(`gbridge.sdui: surface "${surface.id}" requires render() function`);
    }
    const id = surface.id.trim();
    const entry = {
      id,
      title: String(surface.title || id),
      subtitle: typeof surface.subtitle === 'string' ? surface.subtitle : '',
      icon: typeof surface.icon === 'string' ? surface.icon : 'squares_four',
      placement: surface.placement || 'tools', // 'tools' | 'settings' | 'session_tab'
      order: typeof surface.order === 'number' ? surface.order : 100,
      render: surface.render,
      onAction: typeof surface.onAction === 'function' ? surface.onAction : null,
    };
    this.surfaces.set(id, entry);
    return () => {
      if (this.surfaces.get(id) === entry) this.surfaces.delete(id);
    };
  }

  listSurfaces() {
    return [...this.surfaces.values()]
      .sort((a, b) => a.order - b.order || a.id.localeCompare(b.id))
      .map(({ id, title, subtitle, icon, placement, order }) => ({
        id, title, subtitle, icon, placement, order,
      }));
  }

  async renderView(viewId, context = {}) {
    const entry = this.surfaces.get(viewId);
    if (!entry) {
      throw new GbridgeError(404, 'sdui/view_not_found', `SDUI view "${viewId}" not found`);
    }
    const root = await entry.render(context);
    return {
      v: 1,
      viewId: entry.id,
      title: entry.title,
      generatedAt: Date.now(),
      root,
    };
  }

  async invokeAction(viewId, actionId, payload = {}, context = {}) {
    const entry = this.surfaces.get(viewId);
    if (!entry) {
      throw new GbridgeError(404, 'sdui/view_not_found', `SDUI view "${viewId}" not found`);
    }
    if (!entry.onAction) {
      throw new GbridgeError(400, 'sdui/action_unsupported', `SDUI view "${viewId}" accepts no actions`);
    }
    const result = await entry.onAction(actionId, isPlainObject(payload) ? payload : {}, context);
    return isPlainObject(result) ? result : { ok: true };
  }
}
