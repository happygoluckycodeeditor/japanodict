#!/usr/bin/env python3
"""
Convert the dictionary database from FTS5 to FTS4 for better Android compatibility.
"""

import sqlite3
import sys
from pathlib import Path

def convert_to_fts4(db_path):
    """Convert FTS5 table to FTS4."""
    print(f"Converting {db_path} from FTS5 to FTS4...")
    
    conn = sqlite3.connect(db_path)
    cursor = conn.cursor()
    
    try:
        # Drop the existing FTS5 table
        print("Dropping FTS5 table...")
        cursor.execute("DROP TABLE IF EXISTS dictionary_fts")
        
        # Create FTS4 table with the same structure
        print("Creating FTS4 table...")
        cursor.execute("""
            CREATE VIRTUAL TABLE dictionary_fts USING fts4(
                term,
                reading,
                glosses,
                parts_of_speech,
                tags,
                full_text,
                content='dictionary',
                tokenize=unicode61
            )
        """)
        
        # Populate FTS4 table from dictionary table
        print("Populating FTS4 table...")
        cursor.execute("""
            INSERT INTO dictionary_fts(docid, term, reading, glosses, parts_of_speech, tags, full_text)
            SELECT id, term, reading, glosses, parts_of_speech, tags, full_text
            FROM dictionary
        """)
        
        # Drop old triggers
        cursor.execute("DROP TRIGGER IF EXISTS dictionary_ai")
        cursor.execute("DROP TRIGGER IF EXISTS dictionary_au")
        cursor.execute("DROP TRIGGER IF EXISTS dictionary_ad")
        
        # Create triggers for FTS4
        print("Creating triggers...")
        cursor.execute("""
            CREATE TRIGGER dictionary_ai AFTER INSERT ON dictionary BEGIN
                INSERT INTO dictionary_fts(docid, term, reading, glosses, parts_of_speech, tags, full_text)
                VALUES (new.id, new.term, new.reading, new.glosses, new.parts_of_speech, new.tags, new.full_text);
            END
        """)
        
        cursor.execute("""
            CREATE TRIGGER dictionary_au AFTER UPDATE ON dictionary BEGIN
                UPDATE dictionary_fts 
                SET term = new.term,
                    reading = new.reading,
                    glosses = new.glosses,
                    parts_of_speech = new.parts_of_speech,
                    tags = new.tags,
                    full_text = new.full_text
                WHERE docid = new.id;
            END
        """)
        
        cursor.execute("""
            CREATE TRIGGER dictionary_ad AFTER DELETE ON dictionary BEGIN
                DELETE FROM dictionary_fts WHERE docid = old.id;
            END
        """)
        
        conn.commit()
        print("✓ Conversion completed successfully!")
        
        # Verify the conversion
        cursor.execute("SELECT COUNT(*) FROM dictionary_fts")
        count = cursor.fetchone()[0]
        print(f"✓ FTS4 table contains {count:,} entries")
        
    except Exception as e:
        print(f"✗ Error during conversion: {e}")
        conn.rollback()
        sys.exit(1)
    finally:
        conn.close()

if __name__ == "__main__":
    db_path = Path(__file__).parent.parent / "assets" / "databases" / "jitendex_flattened.db"
    
    if not db_path.exists():
        print(f"Error: Database not found at {db_path}")
        sys.exit(1)
    
    convert_to_fts4(str(db_path))
