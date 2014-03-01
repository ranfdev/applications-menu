// -*- Mode: vala; indent-tabs-mode: nil; tab-width: 4 -*-
//
//  Copyright (C) 2011-2012 Slingshot Developers
//
//  This program is free software: you can redistribute it and/or modify
//  it under the terms of the GNU General Public License as published by
//  the Free Software Foundation, either version 3 of the License, or
//  (at your option) any later version.
//
//  This program is distributed in the hope that it will be useful,
//  but WITHOUT ANY WARRANTY; without even the implied warranty of
//  MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
//  GNU General Public License for more details.
//
//  You should have received a copy of the GNU General Public License
//  along with this program.  If not, see <http://www.gnu.org/licenses/>.
//

public class Slingshot.Backend.AppSystem : Object {

    private Gee.ArrayList<GMenu.TreeDirectory> categories = null;
    private Gee.HashMap<string, Gee.ArrayList<App>> apps = null;
    private GMenu.Tree apps_menu = null;

#if HAVE_ZEITGEIST
    private RelevancyService rl_service;
#endif

    public signal void changed ();

    construct {

#if HAVE_ZEITGEIST
        rl_service = new RelevancyService ();
        rl_service.update_complete.connect (update_popularity);
#endif

        apps_menu = new GMenu.Tree ("pantheon-applications.menu", GMenu.TreeFlags.INCLUDE_EXCLUDED | GMenu.TreeFlags.SORT_DISPLAY_NAME);
        apps_menu.changed.connect (update_app_system);
        
        apps = new Gee.HashMap<string, Gee.ArrayList<App>> ();
        categories = new Gee.ArrayList<GMenu.TreeDirectory> ();

        update_app_system ();

    }

    private void update_app_system () {

        debug ("Updating Applications menu tree...");
#if HAVE_ZEITGEIST
        rl_service.refresh_popularity ();
#endif
        try {
            apps_menu.load_sync ();
        } catch (Error e) {
            warning (e.message);
        }

        update_categories_index ();
        update_apps ();

        changed ();

    }

    private void update_categories_index () {

        categories.clear ();

        var iter = apps_menu.get_root_directory ().iter ();
        GMenu.TreeItemType type;
        while ((type = iter.next ()) != GMenu.TreeItemType.INVALID) {
            if (type == GMenu.TreeItemType.DIRECTORY) {
                var dir = iter.get_directory ();
                if (!dir.get_is_nodisplay ())
                    categories.add (dir);
            }
        }

    }

#if HAVE_ZEITGEIST
    private void update_popularity () {

        foreach (Gee.ArrayList<App> category in apps.values)
            foreach (App app in category)
                app.popularity = rl_service.get_app_popularity (app.desktop_id);
    }
#endif

    private void update_apps () {

        apps.clear ();

        foreach (var cat in categories)
            apps.set (cat.get_name (), get_apps_by_category (cat));

    }

    public Gee.ArrayList<GMenu.TreeDirectory> get_categories () {

        return categories;

    }

    public Gee.ArrayList<App> get_apps_by_category (GMenu.TreeDirectory category) {

        var app_list = new Gee.ArrayList<App> ();

        var iter = category.iter ();
        GMenu.TreeItemType type;
        while ((type = iter.next ()) != GMenu.TreeItemType.INVALID) {
            switch (type) {
                case GMenu.TreeItemType.DIRECTORY:
                    app_list.add_all (get_apps_by_category (iter.get_directory ()));
                    break;
                case GMenu.TreeItemType.ENTRY:
                    var app = new App (iter.get_entry ());
#if HAVE_ZEITGEIST
                    app.launched.connect (rl_service.app_launched);
#endif
                    app_list.add (app);
                    break;
            }
        }

        return app_list;

    }

    public Gee.HashMap<string, Gee.ArrayList<App>> get_apps () {

        return apps;

    }

    public SList<App> get_apps_by_popularity () {

        var sorted_apps = new SList<App> ();

        foreach (Gee.ArrayList<App> category in apps.values) {
            foreach (App app in category) {
                sorted_apps.insert_sorted_with_data (app, Utils.sort_apps_by_popularity);
            }
        }

        return sorted_apps;

    }

    public SList<App> get_apps_by_name () {

        var sorted_apps = new SList<App> ();
        string[] sorted_apps_execs = {};

        foreach (Gee.ArrayList<App> category in apps.values) {
            foreach (App app in category) {
                if (!(app.exec in sorted_apps_execs)) {
                    sorted_apps.insert_sorted_with_data (app, Utils.sort_apps_by_name);
                    sorted_apps_execs += app.exec;
                }
            }
        }

        return sorted_apps;

    }

    public async Gee.ArrayList<App> search_results (string search) {

        Idle.add (search_results.callback, Priority.HIGH);
        yield;

        var filtered = new Gee.ArrayList<App> ();

        /** It's a bit stupid algorithm, simply check if the char is present
         * some of the App values, then assign it a double. This is very simple:
         * if an App name coincide with the search string they have obvious the
         * same length, then the fraction will be 1.0.
         * I've added a small multiplier when matching to a exec name, to give
         * more priority to app.name
        **/
        string[] sorted_apps_execs = {};

        foreach (Gee.ArrayList<App> category in apps.values) {
            foreach (App app in category) {
                if (!(app.exec in sorted_apps_execs)) {
                    sorted_apps_execs += app.exec;
                    if (search in app.name.down ()) {
                        if (search == app.name.down ()[0:search.length])
                            app.relevancy = 0.5 - app.popularity; // It must be minor than 1.0
                        else
                            app.relevancy = app.name.length / search.length - app.popularity;
                        filtered.add (app);
                    } else if (search in app.exec.down ()) {
                        app.relevancy = app.exec.length / search.length * 10.0 - app.popularity;
                        filtered.add (app);
                    } else if (search in app.description.down ()) {
                        app.relevancy = app.description.length / search.length - app.popularity;
                        filtered.add (app);
                    } else if (search in app.generic_name.down ()) {
                        app.relevancy = app.generic_name.length / search.length - app.popularity;
                        filtered.add (app);
                    }  else if (app.keywords != null) {
                        app.relevancy = 0;
                        foreach (string keyword in app.keywords) {
                            foreach (string search_word in search.split (" ")) {
                                if (search_word in keyword.down ()) {
                                    app.relevancy += (keyword.length / search_word.length) * (app.keywords.length / search.split (" ").length) - app.popularity;
                                    filtered.add (app);
                                }
                            }
                        }
                    }
                }
            }
        }

        filtered.sort ((a, b) => Utils.sort_apps_by_relevancy ((App) a, (App) b));

        if (filtered.size > 20) {
            return (Gee.ArrayList<App>) filtered[0:20];
        } else {
            return filtered;
        }

    }

}