/* Copyright (C) 2026 Sebastian Matkovich
 * This file is part of 0 A.D.
 *
 * 0 A.D. is free software: you can redistribute it and/or modify
 * it under the terms of the GNU General Public License as published by
 * the Free Software Foundation, either version 2 of the License, or
 * (at your option) any later version.
 *
 * 0 A.D. is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
 * GNU General Public License for more details.
 *
 * You should have received a copy of the GNU General Public License
 * along with 0 A.D.  If not, see <http://www.gnu.org/licenses/>.
 */

#ifndef INCLUDED_DISPLAYROTATION
#define INCLUDED_DISPLAYROTATION

#include "lib/external_libraries/libsdl.h"

/**
 * Self-rotation for phone compositors.
 *
 * Sailfish hands out a portrait surface and offers no way to ask for a
 * landscape one - neither the Qt Wayland content-orientation hint nor an
 * explicit window size changes what the compositor returns. 0 A.D.'s UI is
 * built for wide screens and is unusable at 1032x2272, so the engine turns
 * itself instead:
 *
 *  - everything above the graphics backend works in a LOGICAL landscape
 *    resolution (the physical size with width and height exchanged),
 *  - the finished frame lands in an offscreen framebuffer of that size and is
 *    blitted rotated into the real portrait surface on Present,
 *  - coordinates of incoming input events are rotated the same way, so the
 *    engine only ever sees logical ones.
 *
 * Controlled by "display.rotation" (0, 90 or 270), 0 by default - every other
 * platform is therefore unaffected. The environment variable
 * PYROGENESIS_DISPLAY_ROTATION overrides it for quick experiments.
 *
 * 90 pairs with the compositor hint SDL_QTWAYLAND_CONTENT_ORIENTATION=landscape,
 * 270 with inverted-landscape.
 */
namespace DisplayRotation
{

/**
 * @return 0, 90 or 270. Read from the config on first use, so it must not be
 * called before the config has been loaded.
 */
int GetAngle();

inline bool IsActive() { return GetAngle() != 0; }

/**
 * Remembers the real, unrotated size of the surface. Everything else in the
 * engine works with the logical one, so this is the only place that knows it.
 */
void SetPhysicalSize(int width, int height);

/**
 * Rotates an event's coordinates from physical surface space into logical
 * space. Called once for every event coming out of SDL - and only for those:
 * events the engine synthesises itself (the touch layer does) already carry
 * logical coordinates.
 */
void TransformEvent(SDL_Event& ev);

}

#endif // INCLUDED_DISPLAYROTATION
