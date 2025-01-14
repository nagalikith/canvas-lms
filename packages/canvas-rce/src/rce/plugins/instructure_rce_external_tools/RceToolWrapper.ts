/*
 * Copyright (C) 2023 - present Instructure, Inc.
 *
 * This file is part of Canvas.
 *
 * Canvas is free software: you can redistribute it and/or modify it under
 * the terms of the GNU Affero General Public License as published by the Free
 * Software Foundation, version 3 of the License.
 *
 * Canvas is distributed in the hope that it will be useful, but WITHOUT ANY
 * WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR
 * A PARTICULAR PURPOSE. See the GNU Affero General Public License for more
 * details.
 *
 * You should have received a copy of the GNU Affero General Public License along
 * with this program. If not, see <http://www.gnu.org/licenses/>.
 */

import formatMessage from '../../../format-message'
import {ExternalToolsEnv, RceLtiToolInfo} from './ExternalToolsEnv'
import {openToolDialogFor} from './dialog-helper'
import {simpleCache} from '../../../util/simpleCache'

/**
 * Helper class for the connection between an external tool registration and a particular TinyMCE instance.
 */
export class RceToolWrapper {
  static forEditorEnv(
    env: ExternalToolsEnv,
    toolConfigs = env.availableRceLtiTools,
    mruIds = loadMruToolIds()
  ): RceToolWrapper[] {
    return toolConfigs.map(it => new RceToolWrapper(env, it, mruIds))
  }

  public readonly iconId: string | null | undefined

  public isMruTool: boolean

  get editor() {
    return this.env.editor
  }

  constructor(
    public readonly env: ExternalToolsEnv,
    private readonly toolInfo: RceLtiToolInfo,
    mruToolIds: string[]
  ) {
    this.iconId =
      toolInfo.icon_url != null ? registerToolIcon(env, toolInfo) : toolInfo.canvas_icon_class
    this.isMruTool = mruToolIds.includes(String(toolInfo.id))
  }

  get id(): string {
    return String(this.toolInfo.id)
  }

  get title(): string {
    return this.toolInfo.name ?? `Unknown tool (${String(this.toolInfo.id)})`
  }

  get description(): string | null | undefined {
    return this.toolInfo.description
  }

  get favorite(): boolean {
    return this.toolInfo.favorite ?? false
  }

  get image(): string | null | undefined {
    return this.toolInfo.icon_url
  }

  get width(): number | null | undefined {
    return this.toolInfo.width
  }

  get height(): number | null | undefined {
    return this.toolInfo.height
  }

  get use_tray(): boolean | null | undefined {
    return this.toolInfo.use_tray
  }

  asButton() {
    return {
      type: 'button',
      text: this.title,
      icon: this.iconId ?? undefined,
      tooltip: this.title,
      onAction: () => this.openDialog(),
    } as const
  }

  asMenuItem() {
    return {
      type: 'menuitem',
      text: this.title,
      icon: this.iconId ?? undefined,
      onAction: () => this.openDialog(),
    } as const
  }

  openDialog(): void {
    updateExternalToolMruButtonVisibility(this.env)
    addMruToolId(this.id, this.env)
    openToolDialogFor(this)
  }
}

function registerToolIcon(env: ExternalToolsEnv, toolInfo: RceLtiToolInfo): string | undefined {
  if (env.editor == null) return undefined
  if (toolInfo.icon_url == null || toolInfo.icon_url === '') return undefined

  const iconId = 'lti_tool_' + String(toolInfo.id)

  env.editor.ui.registry.addIcon(iconId, svgImageCache.get(toolInfo.icon_url))

  return iconId
}

const svgImageCache = simpleCache((imageUrl: string) => {
  // Sanitize input against XSS
  const svg = document.createElement('svg')
  svg.setAttribute('viewBox', '0 0 16 16')
  svg.setAttribute('version', '1.1')
  svg.setAttribute('xmlns', 'http://www.w3.org/2000/svg')

  const image = document.createElement('image')
  image.setAttribute('xlink:href', imageUrl)
  image.style.width = '100%'
  image.style.height = '100%'

  svg.appendChild(image)

  return svg.outerHTML
})

export function updateExternalToolMruButtonVisibility(env: ExternalToolsEnv): void {
  if (env.editor == null) return

  const label = formatMessage('Apps')
  const menubutton = env.editor.editorContainer.querySelector(
    `.tox-tbtn--select[aria-label="${label}"]`
  )
  const button = env.editor.editorContainer.querySelector(`.tox-tbtn[aria-label="${label}"]`)

  menubutton?.setAttribute('aria-hidden', 'false')
  button?.setAttribute('aria-hidden', 'true')
}

/**
 * Loads the list of most recently used external tool ids.
 */
export function loadMruToolIds(): string[] {
  let list: unknown

  try {
    list = JSON.parse(window.localStorage?.getItem('ltimru') ?? '[]')
  } catch (ex) {
    // eslint-disable-next-line no-console
    console.warn('Found bad LTI MRU data', (ex as Error).message)
  }

  return Array.isArray(list) ? list.filter(it => it != null).map(it => String(it)) : []
}

/**
 * Loads the list of most recently used external tool ids.
 */
export function storeMruToolIds(toolIds: string[]): void {
  try {
    window.localStorage?.setItem('ltimru', JSON.stringify(toolIds))
  } catch (ex) {
    // eslint-disable-next-line no-console
    console.warn('Cannot save LTI MRU list', (ex as Error).message)
  }
}

export function addMruToolId(toolId: string, env: ExternalToolsEnv): string[] {
  const initialMruToolIds = loadMruToolIds()

  if (!initialMruToolIds.includes(toolId)) {
    const newToolIds = [toolId, ...initialMruToolIds.slice(0, env.maxMruTools - 1)]
    storeMruToolIds(newToolIds)
    return newToolIds
  }

  return initialMruToolIds
}
