package io.github.okiyashko1337.felicitydashboard;

import org.junit.Test;
import static org.junit.Assert.assertEquals;

public final class EventFiltersTest {
    @Test public void streetDefaultsToPeopleAndAnimals(){
        assertEquals(EventFilters.PERSON|EventFilters.ANIMAL,EventFilters.defaultMask(new CameraCatalog.Camera("nvr99","Улица","host")));
        assertEquals(EventFilters.PERSON|EventFilters.ANIMAL,EventFilters.defaultMask(new CameraCatalog.Camera("other","Street","host")));
    }

    @Test public void otherCamerasDefaultToAllAiTypes(){
        assertEquals(EventFilters.ALL,EventFilters.defaultMask(new CameraCatalog.Camera("nvr03","Kitchen hik-AI","host")));
    }
}
