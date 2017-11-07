/*-
 * Copyright (c) 2017 elementary LLC. (https://elementary.io)
 *
 * This program is free software: you can redistribute it and/or modify
 * it under the terms of the GNU General Public License as published by
 * the Free Software Foundation, either version 3 of the License, or
 * (at your option) any later version.
 *
 * This program is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
 * GNU General Public License for more details.
 *
 * You should have received a copy of the GNU General Public License
 * along with this program.  If not, see <http://www.gnu.org/licenses/>.
 *
 * Authored by: Adam Bieńkowski <donadigos159@gmail.com>
 */

public class AppCenterCore.PackageIndex : Gee.TreeSet<Pk.Package> { 
    public signal void added (Pk.Package package);
    public signal void removed (Pk.Package package);

    public bool ready { get; set; default = false; }

    public override bool add (Pk.Package package) {
        added (package);
        return base.add (package);
    }

    public override bool remove (Pk.Package package) {
        removed (package);
        return base.remove (package);
    }
}