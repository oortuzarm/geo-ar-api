class SeedOnboardingData < ActiveRecord::Migration[7.2]
  def up
    now = Time.current

    # ── Categories (Step 2 — visual cards) ───────────────────────────────────
    categories = [
      { name: "Turismo y gastronomía", slug: "tourism",    icon_name: "🗺️",  position: 1 },
      { name: "Eventos",               slug: "events",    icon_name: "🎪",  position: 2 },
      { name: "Educación",             slug: "education", icon_name: "📚",  position: 3 },
      { name: "Bienes raíces",         slug: "realestate",icon_name: "🏠",  position: 4 },
      { name: "Salud y deportes",      slug: "health",    icon_name: "🏃",  position: 5 },
      { name: "Patrimonio cultural",   slug: "heritage",  icon_name: "🏛️",  position: 6 },
      { name: "Logística",             slug: "logistics", icon_name: "🚚",  position: 7 },
      { name: "Otro",                  slug: "other",     icon_name: "✦",   position: 8 },
    ]

    categories.each do |c|
      execute <<~SQL
        INSERT INTO onboarding_categories (name, slug, icon_name, position, active, usage_count, created_at, updated_at)
        VALUES (#{quote(c[:name])}, #{quote(c[:slug])}, #{quote(c[:icon_name])}, #{c[:position]}, TRUE, 0, '#{now.iso8601}', '#{now.iso8601}')
      SQL
    end

    # ── Options (Step 3) ─────────────────────────────────────────────────────
    options = [
      # industry
      { group: "industry", slug: "tourism",      name: "Turismo",                           position: 1  },
      { group: "industry", slug: "hospitality",  name: "Hotelería y alojamiento",           position: 2  },
      { group: "industry", slug: "food",         name: "Gastronomía",                       position: 3  },
      { group: "industry", slug: "events",       name: "Eventos y entretenimiento",         position: 4  },
      { group: "industry", slug: "education",    name: "Educación",                         position: 5  },
      { group: "industry", slug: "realestate",   name: "Bienes raíces",                     position: 6  },
      { group: "industry", slug: "health",       name: "Salud y bienestar",                 position: 7  },
      { group: "industry", slug: "sports",       name: "Deportes y fitness",                position: 8  },
      { group: "industry", slug: "culture",      name: "Arte y cultura",                    position: 9  },
      { group: "industry", slug: "logistics",    name: "Logística y transporte",            position: 10 },
      { group: "industry", slug: "tech",         name: "Tecnología",                        position: 11 },
      { group: "industry", slug: "media",        name: "Medios y comunicación",             position: 12 },
      { group: "industry", slug: "ngo",          name: "ONGs y organizaciones sin fines de lucro", position: 13 },
      { group: "industry", slug: "government",   name: "Gobierno y sector público",         position: 14 },
      { group: "industry", slug: "other",        name: "Otro",                              position: 15 },

      # org_type
      { group: "org_type", slug: "freelancer",   name: "Individual / Freelancer",           position: 1 },
      { group: "org_type", slug: "startup",      name: "Startup / Emprendimiento",          position: 2 },
      { group: "org_type", slug: "sme",          name: "PyME",                              position: 3 },
      { group: "org_type", slug: "mid_company",  name: "Empresa mediana",                   position: 4 },
      { group: "org_type", slug: "enterprise",   name: "Gran empresa",                      position: 5 },
      { group: "org_type", slug: "ngo",          name: "Organización sin fines de lucro",   position: 6 },
      { group: "org_type", slug: "government",   name: "Gobierno / Sector público",         position: 7 },
      { group: "org_type", slug: "education",    name: "Educación / Universidad",           position: 8 },

      # org_size
      { group: "org_size", slug: "solo",         name: "Solo yo",                           position: 1 },
      { group: "org_size", slug: "2_10",         name: "2–10 personas",                     position: 2 },
      { group: "org_size", slug: "11_50",        name: "11–50 personas",                    position: 3 },
      { group: "org_size", slug: "51_200",       name: "51–200 personas",                   position: 4 },
      { group: "org_size", slug: "200_plus",     name: "200+ personas",                     position: 5 },

      # objective
      { group: "objective", slug: "tourism_exp",  name: "Crear experiencias turísticas",             position: 1 },
      { group: "objective", slug: "event_guide",  name: "Guiar a visitantes en un evento",           position: 2 },
      { group: "objective", slug: "showcase",     name: "Mostrar propiedades o locales",             position: 3 },
      { group: "objective", slug: "education",    name: "Enseñar con recorridos interactivos",       position: 4 },
      { group: "objective", slug: "heritage",     name: "Informar sobre patrimonio o cultura",       position: 5 },
      { group: "objective", slug: "logistics",    name: "Gestionar logística con geolocalización",   position: 6 },
      { group: "objective", slug: "other",        name: "Otro",                                      position: 7 },
    ]

    options.each do |o|
      execute <<~SQL
        INSERT INTO onboarding_options (group, name, slug, position, active, usage_count, created_at, updated_at)
        VALUES (#{quote(o[:group])}, #{quote(o[:name])}, #{quote(o[:slug])}, #{o[:position]}, TRUE, 0, '#{now.iso8601}', '#{now.iso8601}')
      SQL
    end
  end

  def down
    execute "DELETE FROM onboarding_options"
    execute "DELETE FROM onboarding_categories"
  end
end
